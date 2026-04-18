module CrystalLanguageServer
  module Handlers
    # `textDocument/rename` — reuses the scanner's reference search and
    # packages each hit as a `TextEdit`. Returned shape is a LSP
    # `WorkspaceEdit` keyed by URI.
    #
    # Safety caveat inherited from References: matches are lexical, so
    # renaming a method `foo` will also rewrite any unrelated local
    # named `foo`. Editors typically show a diff preview before
    # applying; review it. We refuse renames to empty/obviously-invalid
    # identifiers so the server doesn't produce a broken buffer.
    module Rename
      extend self

      VALID_NAME = /\A[A-Za-z_][A-Za-z0-9_]*[?!]?\z/

      def handle(ws : Workspace, params : JSON::Any)
        new_name = params["newName"].as_s
        return nil unless VALID_NAME.matches?(new_name)

        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)
        word = Scanner.word_at(doc.text, byte_offset)
        return nil unless word && !word.empty?

        # Preserve sigils in both search and rewrite: renaming an ivar
        # should keep the `@` prefix on every target.
        target = Scanner.extend_with_sigils(doc.text, byte_offset, word)
        replacement = target[0...target.size - word.size] + new_name

        refs = WorkspaceIndex.find_references(ws, target)
        return nil if refs.empty?

        # Group by URI so the client applies one batch per file.
        by_uri = Hash(String, Array(NamedTuple(range: LspRange, newText: String))).new
        refs.each do |r|
          file_uri = r.file == DocumentUri.to_path(uri) ? uri : DocumentUri.from_path(r.file)
          by_uri[file_uri] ||= [] of NamedTuple(range: LspRange, newText: String)
          by_uri[file_uri] << {
            range: LspRange.new(
              LspPosition.new(r.line, r.column),
              LspPosition.new(r.line, r.column + r.length),
            ),
            newText: replacement,
          }
        end

        {changes: by_uri}
      end
    end
  end
end
