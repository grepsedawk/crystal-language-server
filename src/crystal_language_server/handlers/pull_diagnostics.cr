module CrystalLanguageServer
  module Handlers
    # `textDocument/diagnostic` — LSP 3.17 pull-diagnostic model.
    #
    # The push handler (`Handlers::Diagnostics`) still fires on
    # didOpen/didChange/didSave; this returns the same data on demand
    # so editors that prefer pull (or want to refresh after an
    # external action) can ask without waiting for a publish event.
    #
    # Underlying compile is shared via `Compiler::Provider`'s
    # build_diagnostics cache: pull and push on the same source hash
    # serve from a single compile.
    module PullDiagnostics
      extend self

      KIND_FULL = "full"

      def handle(ws : Workspace, params : JSON::Any, cancel_token : CancelToken? = nil)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return empty_report unless doc

        path = DocumentUri.to_path(uri)
        errors = ws.compiler.build_diagnostics(path, doc.text, cancel_token)
        items = errors.map(&.to_diagnostic(path))

        {kind: KIND_FULL, items: items}
      rescue ex
        Log.warn(exception: ex) { "pull diagnostics failed for #{uri}" }
        empty_report
      end

      private def empty_report
        {kind: KIND_FULL, items: [] of Protocol::Diagnostic}
      end
    end
  end
end
