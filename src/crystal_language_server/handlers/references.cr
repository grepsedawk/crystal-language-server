module CrystalLanguageServer
  module Handlers
    # `textDocument/references` — scanner-driven find-across-workspace.
    # Honors `context.includeDeclaration`: when false, we filter out
    # the definition sites returned by WorkspaceIndex.find_defs.
    #
    # Limitations inherited from the scanner: we match on bare name,
    # so `foo.bar` and a local `bar` collide. A compiler-aware solution
    # would narrow by receiver type. The current trade-off: sometimes
    # we return false positives; we never miss the real hit.
    module References
      extend self

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)
        target = Scanner.user_identifier_at(doc.text, byte_offset)
        return nil unless target && !target.empty?
        bare = Scanner.strip_sigils(target)
        include_decl = params.dig?("context", "includeDeclaration").try(&.as_bool?) != false

        # Locals bound inside an enclosing def shouldn't bleed across
        # files — a cursor on `cc` that's a parameter in this def must
        # not pull in a same-named `cc` local from another file. When
        # we can prove the identifier is locally bound, narrow refs to
        # the def's token range in this document.
        if local_refs = scope_local_references(doc, uri, line, target)
          return local_refs
        end

        # `Mode::Spruce` at the cursor should return refs to the
        # qualified member only, not every bare `Spruce` token that
        # might name an unrelated top-level class.
        if qualified = Scanner.qualified_name_at(doc.text, byte_offset)
          return qualified_references(ws, uri, qualified)
        end

        refs = WorkspaceIndex.find_references(ws, target)

        # Method-declaration cursors (cursor sits on the name_token of
        # an enclosing def) call for callsite-only matching: bare
        # `bot` tokens that happen to be unrelated locals shouldn't
        # answer "find references to this method." Keep only
        # declarations (def sites) and explicit receiver-prefixed calls
        # (`.bot` / `::bot`).
        if cursor_on_def_name?(doc, byte_offset)
          refs = filter_method_reference_sites(ws, refs, bare, doc, uri, line)
        end

        if !include_decl
          defs = WorkspaceIndex.find_defs(ws, bare, priority_doc: doc)
          def_set = defs.map { |d| {d.file, d.line, d.column} }.to_set
          refs = refs.reject { |r| def_set.includes?({r.file, r.line, r.column}) }
        end

        refs.map do |r|
          file_uri = r.file == DocumentUri.to_path(uri) ? uri : DocumentUri.from_path(r.file)
          {
            uri:   file_uri,
            range: LspRange.new(
              LspPosition.new(r.line, r.column),
              LspPosition.new(r.line, r.column + r.length),
            ),
          }
        end
      end

      private def cursor_on_def_name?(doc : Document, byte_offset : Int32) : Bool
        doc.symbols.each do |root|
          return true if descends_to_def_name?(root, byte_offset)
        end
        false
      end

      private def descends_to_def_name?(node : Scanner::SymbolNode, byte_offset : Int32) : Bool
        name_tok = node.name_token
        if (node.kind == Protocol::SymbolKind::METHOD || node.kind == Protocol::SymbolKind::FUNCTION) &&
           byte_offset >= name_tok.byte_start && byte_offset < name_tok.byte_end
          return true
        end
        node.children.each do |c|
          return true if descends_to_def_name?(c, byte_offset)
        end
        false
      end

      # Restrict `refs` to method-call occurrences:
      #   * Declarations (`def name`).
      #   * Tokens preceded by `.` or `::` (explicit receiver calls).
      #   * Bare tokens whose enclosing class sits in the cursor's
      #     class hierarchy AND whose enclosing def does not locally
      #     bind `name`. Bare tokens in unrelated classes are dropped —
      #     otherwise a `BotModule#bot` lookup pulls in every `bot`
      #     call inside an unrelated `AdminBot` which has its own
      #     `def bot`.
      private def filter_method_reference_sites(ws : Workspace, refs : Array(WorkspaceIndex::Reference), name : String, priority_doc : Document, priority_uri : String, cursor_line : Int32) : Array(WorkspaceIndex::Reference)
        priority_path = DocumentUri.to_path(priority_doc.uri)
        def_sites = WorkspaceIndex.find_defs(ws, name, priority_doc: priority_doc)
        def_set = def_sites.map { |d| {d.file.empty? ? priority_path : d.file, d.line, d.column} }.to_set

        open_tokens = {} of String => Array(Scanner::Token)
        open_symbols = {} of String => Array(Scanner::SymbolNode)
        ws.documents.each do |d|
          path = DocumentUri.to_path(d.uri)
          open_tokens[path] = d.tokens
          open_symbols[path] = d.symbols
        end
        hierarchy = cursor_hierarchy_set(ws, priority_doc, cursor_line)
        token_cache = {} of String => Array(Scanner::Token)
        locality_cache = {} of Tuple(String, Int32) => Bool

        refs.compact_map do |ref|
          next ref if def_set.includes?({ref.file, ref.line, ref.column})

          tokens = token_cache[ref.file]? || (
            src = open_tokens[ref.file]? || WorkspaceIndex.tokens_for(ref.file)
            next nil unless src
            token_cache[ref.file] = src
          )
          idx = tokens.index { |t| t.line == ref.line && t.column == ref.column }
          next nil unless idx

          prev = Scanner.previous_non_whitespace(tokens, idx)
          next ref if prev && (prev.text == "." || prev.text == "::")

          # Bare occurrence — drop unless the enclosing class is in
          # the cursor's hierarchy AND the enclosing def doesn't bind
          # the name as a local.
          symbols = open_symbols[ref.file]? || WorkspaceIndex.symbols_for(ref.file)
          next nil unless symbols

          if hierarchy
            enclosing = Scanner.enclosing_type(symbols, ref.line)
            next nil unless enclosing && hierarchy.includes?(enclosing.name)
          end

          scope = Scanner.enclosing_callable(symbols, ref.line)
          if scope
            bound = locality_cache[{ref.file, scope.opener.line}] ||= Scanner.locally_bound?(tokens, scope, name)
          else
            bound = locality_cache[{ref.file, -1}] ||= Scanner.bound_anywhere?(tokens, name)
          end
          bound ? nil : ref
        end
      end

      # Returns the set of class/struct/module names forming the
      # hierarchy the cursor sits in: the enclosing type plus all
      # transitive subclasses. Nil when there's no enclosing type — in
      # that case no hierarchy gate is applied and bare refs are
      # accepted anywhere.
      private def cursor_hierarchy_set(ws : Workspace, doc : Document, cursor_line : Int32) : Set(String)?
        enclosing = Scanner.enclosing_type(doc.symbols, cursor_line)
        return nil unless enclosing
        # Compare on the last `::` chunk so `Hive::BotModule` and
        # `BotModule` both hit.
        Handlers::TypeHierarchy.hierarchy_set_for(ws, enclosing.name.split("::").last)
      end

      private def qualified_references(ws : Workspace, uri : String, qualified : String)
        refs = WorkspaceIndex.find_qualified_references(ws, qualified)
        seen = refs.map { |r| {r.file, r.line, r.column} }.to_set

        # Include the declaration: enum members are line-leading
        # Constants with no `Mode::` prefix in their source, so
        # qualified-prefix scanning wouldn't find them.
        WorkspaceIndex.find_defs(ws, qualified).each do |site|
          next if site.file.empty?
          key = {site.file, site.line, site.column}
          next if seen.includes?(key)
          seen << key
          refs << WorkspaceIndex::Reference.new(
            file: site.file,
            line: site.line,
            column: site.column,
            length: qualified.split("::").last.size,
          )
        end

        refs.map do |r|
          file_uri = r.file == DocumentUri.to_path(uri) ? uri : DocumentUri.from_path(r.file)
          {
            uri:   file_uri,
            range: LspRange.new(
              LspPosition.new(r.line, r.column),
              LspPosition.new(r.line, r.column + r.length),
            ),
          }
        end
      end

      private def scope_local_references(doc : Document, uri : String, line : Int32, name : String)
        return nil if name.empty?
        first = name[0]
        return nil if first.ascii_uppercase?
        return nil if first == '@' || first == '$'

        scope = Scanner.enclosing_callable(doc.symbols, line)
        return nil unless scope
        return nil unless Scanner.locally_bound?(doc.tokens, scope, name)

        start_line = scope.opener.line
        end_line = scope.end_token.try(&.line) || start_line

        doc.tokens.compact_map do |tok|
          next nil unless tok.line >= start_line && tok.line <= end_line
          next nil unless tok.kind == Scanner::Token::Kind::Identifier
          next nil unless tok.text == name
          {
            uri:   uri,
            range: LspRange.new(
              LspPosition.new(tok.line, tok.column),
              LspPosition.new(tok.line, tok.column + tok.text.size),
            ),
          }
        end
      end
    end
  end
end
