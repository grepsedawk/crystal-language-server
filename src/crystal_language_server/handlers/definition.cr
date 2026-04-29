module CrystalLanguageServer
  module Handlers
    module Definition
      extend self

      # Returns one or more `Location`s where the symbol at the cursor
      # is defined. The compiler emits a chain of "expansions" for
      # macro-generated code; we collapse those to the outermost
      # real-file location so goto-definition lands somewhere the user
      # can edit, rather than an internal macro location.
      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        cr_line = line + 1
        cr_column = doc.column_byte_offset(line, character) + 1
        path = DocumentUri.to_path(uri)

        # Fastest path: if the cursor is on an identifier bound inside
        # the enclosing def (parameter, local assignment, block arg),
        # jump to the binding site without consulting the compiler or
        # the workspace.
        local_binding = from_local_binding(doc, uri, line, character)
        return local_binding if local_binding

        byte_offset = doc.position_to_offset(line, character)
        sigil_aware = Scanner.user_identifier_at(doc.text, byte_offset)

        # Sigiled identifiers (@ivar, @@cvar, $global) aren't indexed
        # as SymbolNodes, so find_defs would miss them and silently
        # return the same-named method instead. Scan the current doc's
        # tokens for the first matching sigiled token.
        if sigil_aware && (sigil_aware.starts_with?('@') || sigil_aware.starts_with?('$'))
          return from_sigiled_token(doc, uri, sigil_aware)
        end

        bare_word = sigil_aware && Scanner.strip_sigils(sigil_aware)

        # Prefer a qualified lookup when the cursor sits on `Foo` in
        # `Ns::Foo` — otherwise a bare `Foo` can pick up an unrelated
        # top-level `Foo` that only shares the final segment.
        if qualified = Scanner.qualified_name_at(doc.text, byte_offset)
          if sites = locations_from_index(ws, doc, uri, qualified, qualified.split("::").last.size)
            return sites
          end
        end

        # Fast path: if the scanner finds exactly one unambiguous
        # definition for the identifier, return it immediately. This
        # turns goto-definition from a 2-3s compiler wait into a
        # sub-millisecond scan for the common case (a method defined
        # once in the workspace).
        unambiguous = bare_word && unambiguous_from_workspace(ws, doc, uri, bare_word)
        return unambiguous if unambiguous

        # Otherwise we need compiler disambiguation. Any early-out
        # (nil, failed status, empty implementations list, broken
        # compile) falls through to the workspace-index fallback.
        locations = from_compiler(ws, path, doc.text, cr_line, cr_column)
        return locations if locations && !locations.empty?

        bare_word ? from_workspace(ws, doc, uri, bare_word) : nil
      end

      # Jump to the first token matching `sigiled` (e.g. `@ivar`) in
      # the current document. Ivars/cvars/globals don't show up in
      # WorkspaceIndex.find_defs — that index is scanner-SymbolNode
      # driven and doesn't enumerate assignments.
      private def from_sigiled_token(doc : Document, uri : String, sigiled : String)
        tok = doc.tokens.find do |t|
          (t.kind.i_var? || t.kind.c_var? || t.kind.global?) && t.text == sigiled
        end
        return nil unless tok
        [{
          uri:   uri,
          range: LspRange.new(
            LspPosition.new(tok.line, tok.column),
            LspPosition.new(tok.line, tok.column + tok.text.size),
          ),
        }]
      end

      # Run `find_defs(name)` and only keep results whose symbol name
      # matches the query *exactly*. `find_defs` does a namespace-aware
      # suffix match, which is great for bare lookups but is the wrong
      # behavior once we've resolved the full qualified path.
      private def locations_from_index(ws, doc, uri, qualified : String, word_size : Int32)
        sites = WorkspaceIndex.find_defs(ws, qualified, priority_doc: doc)
        return nil if sites.empty?
        sites.map do |site|
          file_uri = site.file.empty? ? uri : DocumentUri.from_path(site.file)
          {
            uri:   file_uri,
            range: LspRange.new(
              LspPosition.new(site.line, site.column),
              LspPosition.new(site.line, site.column + word_size),
            ),
          }
        end
      end

      # Locate the binding site for an identifier used inside a def:
      # a parameter, a local assignment (`name = ...`), or a block
      # argument (`|name|`). The first identifier-with-this-text
      # inside the enclosing def wins — matches Crystal's own scoping
      # (first binding in lexical order is the definition).
      #
      # Returns nil when the cursor isn't inside a def, or when the
      # word doesn't appear anywhere in that def's body. That lets us
      # fall through to the workspace / compiler paths for top-level
      # calls.
      private def from_local_binding(doc : Document, uri : String, line : Int32, character : Int32)
        byte_offset = doc.position_to_offset(line, character)
        word = Scanner.word_at(doc.text, byte_offset)
        return nil unless word && !word.empty?

        # Skip obvious non-locals: words starting with an uppercase
        # letter (constants/types) or a sigil (@/@@/$). Those are
        # resolved elsewhere.
        first_char = word[0]
        return nil if first_char.ascii_uppercase?
        return nil if first_char == '@' || first_char == '$'

        scope = enclosing_def(doc, line)
        return nil unless scope

        start_line = scope.opener.line
        end_line = scope.end_token.try(&.line) || start_line
        cursor_byte = byte_offset
        def_name_byte = scope.name_token.byte_start

        # Walk tokens in the scope and return the first identifier
        # strictly *before* the cursor that matches the word. Matches
        # at or after the cursor are usages of an unresolved name
        # (library call, undefined symbol) — falling through to the
        # compiler gives the user a real answer or a real "not found".
        doc.tokens.each do |tok|
          next unless tok.line >= start_line && tok.line <= end_line
          next unless tok.kind == Scanner::Token::Kind::Identifier
          next unless tok.text == word
          next if tok.byte_start == def_name_byte
          # Without this, a call like `helper` matches itself as its
          # own "binding" and masks the workspace lookup of the def.
          next if cursor_byte <= tok.byte_end

          return [{
            uri:   uri,
            range: LspRange.new(
              LspPosition.new(tok.line, tok.column),
              LspPosition.new(tok.line, tok.column + tok.text.size),
            ),
          }]
        end
        nil
      end

      private def enclosing_def(doc : Document, line : Int32) : Scanner::SymbolNode?
        Scanner.enclosing_callable(doc.symbols, line)
      end

      # Returns a single-element Location array when the scanner finds
      # exactly one definition site for the word under the cursor.
      # Multiple hits → nil (compiler will disambiguate). Zero hits
      # → nil (nothing local — compiler or stdlib).
      private def unambiguous_from_workspace(ws, doc, uri, word : String)
        return nil if word.empty?
        sites = WorkspaceIndex.find_defs(ws, word, priority_doc: doc)
        return nil if sites.size != 1

        site = sites.first
        file_uri = site.file.empty? ? uri : DocumentUri.from_path(site.file)
        [{
          uri:   file_uri,
          range: LspRange.new(
            LspPosition.new(site.line, site.column),
            LspPosition.new(site.line, site.column + word.size),
          ),
        }]
      end

      private def from_compiler(ws, path, source, line, column)
        json = ws.compiler.implementations(path, source, line, column)
        return nil unless json
        return nil unless json["status"]?.try(&.as_s?) == "ok"
        impls = json["implementations"]?.try(&.as_a?)
        return nil unless impls
        locations = impls.compact_map { |entry| location_from(entry) }
        locations.empty? ? nil : locations
      end

      private def from_workspace(ws, doc, uri, word : String)
        return nil if word.empty?
        sites = WorkspaceIndex.find_defs(ws, word, priority_doc: doc)
        return nil if sites.empty?

        sites.map do |site|
          file_uri = site.file.empty? ? uri : DocumentUri.from_path(site.file)
          {
            uri:   file_uri,
            range: LspRange.new(
              LspPosition.new(site.line, site.column),
              LspPosition.new(site.line, site.column + word.size),
            ),
          }
        end
      end

      private def location_from(entry : JSON::Any)
        # Walk the expansion chain to its deepest concrete frame — i.e.
        # the leafmost entry that points at a real file the user wrote.
        node = entry
        while (expanded = node["expands"]?)
          node = expanded
        end

        file = node["filename"]?.try(&.as_s?)
        line = node["line"]?.try(&.as_i?)
        col = node["column"]?.try(&.as_i?)
        return nil unless file && line && col
        return nil if file.empty? || file == "<unknown>"

        # compiler line/column are 1-based; LSP is 0-based. Size of the
        # target name isn't reported, so we produce a zero-width range.
        start = LspPosition.new(line - 1, col - 1)
        {uri: DocumentUri.from_path(file), range: LspRange.new(start, start)}
      end
    end
  end
end
