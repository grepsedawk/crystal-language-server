module CrystalLanguageServer
  module Handlers
    # `textDocument/typeDefinition` — "go to the class of this
    # expression". Asks the compiler what type the word under the
    # cursor resolves to, strips generic parameters, then looks up the
    # class's definition via WorkspaceIndex.
    module TypeDefinition
      extend self

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)
        word = Scanner.word_at(doc.text, byte_offset)
        return nil unless word && !word.empty?

        path = DocumentUri.to_path(uri)
        cr_line = line + 1
        cr_column = doc.column_byte_offset(line, character) + 1

        types = ws.compiler.context_types(path, doc.text, cr_line, cr_column)
        type_str = types.try &.[word]?
        return nil unless type_str

        type_name = Scanner.strip_type(type_str)
        sites = WorkspaceIndex.find_defs(ws, type_name, priority_doc: doc)
        return nil if sites.empty?

        sites.compact_map do |site|
          next nil if site.file.empty?
          {
            uri:   DocumentUri.from_path(site.file),
            range: LspRange.new(
              LspPosition.new(site.line, site.column),
              LspPosition.new(site.line, site.column + type_name.size),
            ),
          }
        end
      end
    end
  end
end
