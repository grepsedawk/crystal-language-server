module CrystalLanguageServer
  module Handlers
    # The editor blocks the save until this returns, so every action
    # here must be fast and syntactic — no compiler roundtrip, no disk.
    module WillSave
      extend self

      def wait_until(ws : Workspace, params : JSON::Any) : Array(OrganizeImports::RequireEdit)
        case ws.options.will_save_actions
        in .none?
          [] of OrganizeImports::RequireEdit
        in .organize_imports?
          uri = params["textDocument"]["uri"].as_s
          doc = ws.documents[uri]?
          return [] of OrganizeImports::RequireEdit unless doc
          OrganizeImports.edits_for(doc)
        end
      end
    end
  end
end
