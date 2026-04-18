module CrystalLanguageServer
  module Handlers
    # `textDocument/hover` — a three-tier strategy:
    #
    # 1. **Compiler context** (`crystal tool context`). Best answer when
    #    available: real types for variables/args/self at the cursor.
    # 2. **Definition signature** (`crystal tool implementations`).
    #    Available even when the type-checker has no instantiation: we
    #    ask for the definition, open that file, and pull out the `def`
    #    or `class` line plus any preceding `#` doc comment.
    # 3. **Local symbol from the scanner.** If both compiler tools bail
    #    (broken file, no def found), surface the matching SymbolNode's
    #    detail from our own in-memory scan.
    #
    # We used to fall back to just re-printing the word under the
    # cursor, which is useless — nvim already shows you that. Now we
    # return nil instead of a blank hover when there's nothing to say.
    module Hover
      extend self

      def handle(ws : Workspace, params : JSON::Any, cancel_token : CancelToken? = nil)
        uri = params["textDocument"]["uri"].as_s
        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i

        doc = ws.documents[uri]?
        return nil unless doc

        path = DocumentUri.to_path(uri)
        byte_offset = doc.position_to_offset(line, character)
        sigil_aware = Scanner.user_identifier_at(doc.text, byte_offset)
        word = sigil_aware && Scanner.strip_sigils(sigil_aware)
        # A cursor on `Spruce` of `Mode::Spruce` must show the enum
        # member, not an unrelated top-level `class Spruce`. When the
        # source carries a `Ns::` prefix, prefer the qualified lookup.
        qualified = Scanner.qualified_name_at(doc.text, byte_offset)
        cr_line = line + 1
        cr_column = doc.column_byte_offset(line, character) + 1

        # Fast first pass: if the symbol is defined in the current
        # buffer (or any indexed workspace file), answer from the
        # scanner. This is sub-millisecond and covers the common case
        # where the user hovers over a function they just defined.
        # The compiler call is still made as a second pass for inferred
        # types of locals / args / self — only if the scanner answer
        # was empty.
        md = (qualified && from_workspace_index(ws, doc, qualified)) || from_local_symbol(doc, word) || from_workspace_index(ws, doc, word) || from_context(ws, path, doc.text, sigil_aware, cr_line, cr_column, cancel_token) || from_definition(ws, path, doc.text, cr_line, cr_column, cancel_token)
        return nil unless md

        {
          contents: {kind: "markdown", value: md},
          range:    hover_range(doc, byte_offset, word),
        }
      end

      # --- tier 1: compiler context ------------------------------------

      private def from_context(ws, path, source, word, line, column, cancel_token : CancelToken? = nil) : String?
        json = ws.compiler.context(path, source, line, column, cancel_token)
        return nil unless json
        return nil unless json["status"]?.try(&.as_s?) == "ok"
        contexts = json["contexts"]?.try(&.as_a?)
        return nil unless contexts && !contexts.empty?

        ctx = contexts.first.as_h

        # Preferred: the word under cursor has a typed entry.
        if word && ctx.has_key?(word)
          return "```crystal\n#{word} : #{ctx[word]}\n```"
        end

        # Otherwise dump the whole frame — useful on `self`, type names,
        # and inside blocks where the "word" isn't a binding name.
        return nil if ctx.empty?
        lines = ["```crystal"]
        ctx.each { |k, v| lines << "#{k} : #{v}" }
        lines << "```"
        lines.join("\n")
      end

      # --- tier 2: definition lookup -----------------------------------

      private def from_definition(ws, path, source, line, column, cancel_token : CancelToken? = nil) : String?
        json = ws.compiler.implementations(path, source, line, column, cancel_token)
        return nil unless json
        return nil unless json["status"]?.try(&.as_s?) == "ok"
        impls = json["implementations"]?.try(&.as_a?)
        return nil unless impls && !impls.empty?

        # Walk to the deepest concrete frame (past any macro expansions).
        node = impls.first
        while (expanded = node["expands"]?)
          node = expanded
        end

        target_file = node["filename"]?.try(&.as_s?)
        target_line = node["line"]?.try(&.as_i?)
        return nil unless target_file && target_line
        return nil if target_file.empty? || target_file == "<unknown>"

        DefinitionSnippet.render_markdown(target_file, target_line)
      end

      # --- tier 2b: workspace index ------------------------------------
      #
      # When the compiler tools both failed (common for library files
      # that don't compile standalone), ask the scanner to find the
      # identifier across every `.cr` file in the workspace. We show
      # the def's signature plus its source location so hover stays
      # useful across files.

      private def from_workspace_index(ws, doc, word) : String?
        return nil unless word
        sites = WorkspaceIndex.find_defs(ws, word, priority_doc: doc)
        return nil if sites.empty?

        primary = sites.find { |s| !s.file.empty? } || sites.first

        md = if !primary.file.empty? && (snippet = DefinitionSnippet.render_markdown(primary.file, primary.line + 1))
               snippet
             else
               "```crystal\n#{primary.signature || "def #{word}"}\n```"
             end

        if sites.size > 1
          md = "#{md}\n\n_#{sites.size} definitions in workspace_"
        end
        md
      end

      # --- tier 3: local symbol ----------------------------------------

      private def from_local_symbol(doc : Document, word : String?) : String?
        return nil unless word
        match = nil
        doc.symbols.each do |root|
          match ||= find_symbol(root, word)
        end
        return nil unless match

        label = match.detail || match.name
        "```crystal\n#{label}\n```"
      end

      private def find_symbol(node : Scanner::SymbolNode, name : String) : Scanner::SymbolNode?
        return node if node.name == name
        node.children.each do |c|
          if hit = find_symbol(c, name)
            return hit
          end
        end
        nil
      end

      private def hover_range(doc, byte_offset, word)
        return nil unless word
        start = byte_offset
        while start > 0 && Scanner.identifier_char?(doc.text.byte_at(start - 1).unsafe_chr)
          start -= 1
        end
        stop = start + word.bytesize
        LspRange.new(doc.offset_to_position(start), doc.offset_to_position(stop))
      end
    end
  end
end
