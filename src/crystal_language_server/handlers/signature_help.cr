module CrystalLanguageServer
  module Handlers
    # `textDocument/signatureHelp` — floats the active method's
    # signature when the cursor is inside a call's argument list.
    #
    # The heavy lifting is backwards cursor navigation through the
    # current buffer's bytes: from the cursor, walk left skipping
    # balanced parens / brackets / strings, counting top-level commas
    # to derive the active argument index. When we hit an unmatched
    # `(`, the token immediately before it is the method name.
    #
    # We then look up matching `def <name>` symbols — first in the
    # current doc, then across the workspace — and return one
    # `SignatureInformation` per match. We don't try to disambiguate by
    # argument arity; the client shows arrows between overloads.
    module SignatureHelp
      extend self

      MAX_SCAN_BYTES = 4096

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)

        call = find_enclosing_call(doc.text, byte_offset)
        return nil unless call

        candidates = collect_signatures(ws, doc, call[:name])
        return nil if candidates.empty?

        {
          signatures:      candidates,
          activeSignature: 0,
          activeParameter: call[:arg_index],
        }
      end

      # --- scanning ----------------------------------------------------

      # Walk backwards from `pos` looking for the opening `(` of an
      # unbalanced call. Returns the method name and 0-based argument
      # index, or nil if the cursor isn't inside a call.
      private def find_enclosing_call(source : String, pos : Int32)
        depth = 0
        brackets = 0
        braces = 0
        commas = 0
        i = pos - 1
        limit = Math.max(0, pos - MAX_SCAN_BYTES)

        while i >= limit
          ch = source.byte_at(i).unsafe_chr
          case ch
          when ')' then depth += 1
          when ']' then brackets += 1
          when '}' then braces += 1
          when '('
            if depth == 0
              # Found the opening paren we're nested inside.
              name = identifier_before(source, i)
              return nil unless name
              return {name: name, arg_index: commas}
            else
              depth -= 1
            end
          when '['
            return nil if brackets == 0 && depth == 0
            brackets -= 1 if brackets > 0
          when '{'
            braces -= 1 if braces > 0
          when ','
            commas += 1 if depth == 0 && brackets == 0 && braces == 0
          when '"'
            # Skip the string (handle \" escapes minimally).
            i -= 1
            while i >= limit
              c2 = source.byte_at(i).unsafe_chr
              break if c2 == '"' && (i == 0 || source.byte_at(i - 1).unsafe_chr != '\\')
              i -= 1
            end
          when '\n'
            # A bare newline inside the scan (not within parens) almost
            # always means we've walked out of the call expression.
            return nil if depth == 0 && brackets == 0 && braces == 0 && has_stop_boundary?(source, i)
          end
          i -= 1
        end
        nil
      end

      private def has_stop_boundary?(source, nl_pos) : Bool
        # Heuristic: two newlines in a row (blank line) definitely ends
        # the expression; a single one often does not (Crystal allows
        # line continuation inside parens — but we already guard on
        # `depth == 0` above, so this branch only fires when we weren't
        # actually in a call).
        nl_pos >= 1 && source.byte_at(nl_pos - 1).unsafe_chr == '\n'
      end

      private def identifier_before(source : String, paren_pos : Int32) : String?
        i = paren_pos - 1
        # skip whitespace (rare; `foo (x)` — Crystal discourages this but
        # accept it).
        while i >= 0 && source.byte_at(i).unsafe_chr.in?(' ', '\t')
          i -= 1
        end
        stop = i + 1
        while i >= 0 && Scanner.identifier_char?(source.byte_at(i).unsafe_chr)
          i -= 1
        end
        start = i + 1
        return nil if start == stop
        name = source.byte_slice(start, stop - start)
        name.empty? ? nil : name
      end

      # --- lookup ------------------------------------------------------

      private def collect_signatures(ws : Workspace, doc : Document, name : String)
        out = [] of NamedTuple(label: String, parameters: Array(NamedTuple(label: String)), documentation: String?)

        each_def_symbol(doc.symbols) do |node|
          out << render_signature(node) if node.name == name
        end

        # Search workspace only if the local doc didn't match — we
        # don't want to spam the user with unrelated `def foo` from
        # across the shard when they have a local match.
        if out.empty? && (root = ws.root_path)
          found = false
          WorkspaceIndex.each_cr_file(root) do |path|
            next if found
            symbols = WorkspaceIndex.symbols_for(path)
            next unless symbols
            each_def_symbol(symbols) do |node|
              next unless node.name == name
              out << render_signature(node)
              found = true
            end
          end
        end

        out
      end

      private def each_def_symbol(roots : Array(Scanner::SymbolNode), &block : Scanner::SymbolNode ->)
        roots.each { |r| walk_defs(r, &block) }
      end

      private def walk_defs(node : Scanner::SymbolNode, &block : Scanner::SymbolNode ->)
        if node.kind == Protocol::SymbolKind::METHOD || node.kind == Protocol::SymbolKind::FUNCTION
          block.call(node)
        end
        node.children.each { |c| walk_defs(c, &block) }
      end

      private def render_signature(node : Scanner::SymbolNode)
        label = node.detail || "def #{node.name}"
        params = extract_parameters(label)
        {label: label, parameters: params, documentation: nil.as(String?)}
      end

      # Split a scanner-emitted signature like `def foo(a:Int32,b=1)`
      # into LSP `ParameterInformation[]`. We match on the substring of
      # the label so the client can underline each one.
      private def extract_parameters(label : String) : Array(NamedTuple(label: String))
        open_paren = label.index('(')
        close_paren = label.rindex(')')
        return [] of NamedTuple(label: String) unless open_paren && close_paren && close_paren > open_paren

        inside = label[(open_paren + 1)...close_paren]
        return [] of NamedTuple(label: String) if inside.strip.empty?

        # Split on top-level commas — mirrors the scan logic above.
        parts = [] of String
        depth = 0
        buf = String::Builder.new
        inside.each_char do |ch|
          case ch
          when '(', '[', '{' then depth += 1
          when ')', ']', '}' then depth -= 1
          when ','
            if depth == 0
              parts << buf.to_s.strip
              buf = String::Builder.new
              next
            end
          end
          buf << ch
        end
        tail = buf.to_s.strip
        parts << tail unless tail.empty?

        parts.map { |p| {label: p} }
      end
    end
  end
end
