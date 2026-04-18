module CrystalLanguageServer
  module Handlers
    module TextSync
      extend self

      def did_open(ws : Workspace, params : JSON::Any) : String
        td = params["textDocument"]
        uri = td["uri"].as_s
        text = td["text"].as_s
        version = td["version"].as_i
        language = td["languageId"]?.try(&.as_s) || "crystal"
        ws.documents.open(uri, text, version, language)
        uri
      end

      def did_change(ws : Workspace, params : JSON::Any) : String?
        td = params["textDocument"]
        uri = td["uri"].as_s
        version = td["version"].as_i
        changes = params["contentChanges"].as_a

        ws.documents.with_document(uri) do |doc|
          changes.each { |c| doc.apply_change(c) }
          doc.update(doc.text, version)
          WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), doc)
        end
        uri
      end

      def did_close(ws : Workspace, params : JSON::Any) : String
        uri = params["textDocument"]["uri"].as_s
        ws.documents.close(uri)
        Completion.drop_receiver_cache(uri)
        InlayHints.drop(uri)
        SemanticTokens.drop(uri)
        path = DocumentUri.to_path(uri)
        ws.compiler.invalidate_cache(path)
        WorkspaceIndex.reindex_file_from_disk(path)
        uri
      end

      def did_save(ws : Workspace, params : JSON::Any) : String?
        uri = params["textDocument"]["uri"].as_s
        WorkspaceIndex.reindex_file_from_disk(DocumentUri.to_path(uri))
        uri
      end
    end
  end
end
