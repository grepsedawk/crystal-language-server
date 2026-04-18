module CrystalLanguageServer
  module Handlers
    module Formatting
      extend self

      # Reply to `textDocument/formatting` with a single full-document
      # edit containing the formatter's output. We emit one big edit
      # rather than computing a minimal diff — editors reconcile either
      # way and the overhead on typical files is negligible.
      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        formatted = ws.compiler.format(doc.text)
        return nil if formatted.nil? || formatted == doc.text

        range = LspRange.new(
          LspPosition.new(0, 0),
          doc.offset_to_position(doc.text.bytesize),
        )
        [{range: range, newText: formatted}]
      end
    end
  end
end
