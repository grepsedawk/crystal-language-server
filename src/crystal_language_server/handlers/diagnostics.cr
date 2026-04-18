module CrystalLanguageServer
  module Handlers
    # Runs `crystal build --no-codegen -f json` on a document and
    # publishes `textDocument/publishDiagnostics`. Debounced per-uri so
    # rapid typing doesn't spawn a compiler per keystroke.
    class Diagnostics
      def initialize(@workspace : Workspace, @transport : Transport, debounce : Float64? = nil)
        @debounce = debounce || @workspace.options.diagnostics_debounce
        @pending = {} of String => Int64
        @mutex = Mutex.new
        @next_token = 0_i64
      end

      # Schedule a diagnostic run for `uri`. If another `schedule` comes
      # in before the debounce window elapses, the previous generation
      # is abandoned (the running fiber sees a stale token and bails).
      #
      # `trigger` indicates whether this call came from didChange or
      # didSave; combined with `options.diagnostics_trigger` we decide
      # whether to actually run.
      def schedule(uri : String, event : DiagnosticsEvent) : Nil
        return unless should_run?(event)

        token = @mutex.synchronize do
          @next_token += 1
          @pending[uri] = @next_token
        end

        spawn do
          sleep @debounce.seconds
          current = @mutex.synchronize { @pending[uri]? }
          next unless current == token
          run(uri)
        end
      end

      private def should_run?(event : DiagnosticsEvent) : Bool
        case @workspace.options.diagnostics_trigger
        in DiagnosticsTrigger::Never    then false
        in DiagnosticsTrigger::OnSave   then event.save? || event.open?
        in DiagnosticsTrigger::OnChange then true
        end
      end

      private def run(uri : String) : Nil
        doc = @workspace.documents[uri]?
        return unless doc

        path = DocumentUri.to_path(uri)
        errors = @workspace.compiler.build_diagnostics(path, doc.text)

        diagnostics = errors.map(&.to_diagnostic(path))

        @transport.write Protocol.notification(
          "textDocument/publishDiagnostics",
          {uri: uri, diagnostics: diagnostics},
        )
      rescue ex
        Log.warn(exception: ex) { "diagnostics failed for #{uri}" }
      end
    end
  end
end
