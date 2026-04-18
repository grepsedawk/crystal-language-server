module CrystalLanguageServer
  # Main request/notification dispatcher. One instance per process.
  # Handlers live in the `Handlers` submodules; this class only cares
  # about framing, method routing, and server lifecycle (initialized /
  # shutdown / exit).
  class Server
    getter workspace : Workspace
    getter transport : Transport

    def initialize(@options : Options, transport : Transport? = nil)
      CrystalLanguageServer.configure_logging(@options)
      @workspace = Workspace.new(@options)
      @transport = transport || Transport.new
      @diagnostics = Handlers::Diagnostics.new(@workspace, @transport)
      @shutdown_requested = false
      # In-flight requests keyed by the JSON-encoded id. Clients are
      # allowed to reuse ids after the previous use has been answered,
      # so we key on the live id and unregister in an ensure.
      @cancellations = {} of String => CancelToken
      @cancellations_mutex = Mutex.new
      @outbound_id = Atomic(Int64).new(0_i64)
    end

    # Send a request to the client. We don't currently await the
    # response — callers that need one should build a correlation
    # table first. Used for `client/registerCapability` and
    # `window/workDoneProgress/create` where a failure just means the
    # client ignored us, which we can live with.
    def send_outbound_request(method : String, params) : Nil
      id = "cls-out-#{@outbound_id.add(1) + 1}"
      @transport.write Protocol.request(id, method, params)
    end

    # `window/logMessage` notification — surfaces a free-form log line
    # in the client's output panel. `type` is an LSP `MessageType`.
    def send_log_message(type : Int32, message : String) : Nil
      @transport.write Protocol.notification(
        "window/logMessage",
        {type: type, message: message},
      )
    end

    # `window/showDocument` reverse REQUEST — asks the editor to focus
    # or open a URI. The reply (a boolean `success`) is currently
    # discarded; callers that need it must add response correlation.
    def send_show_document(uri : String, *,
                           external : Bool = false,
                           take_focus : Bool = true,
                           selection : LspRange? = nil) : Nil
      if selection
        send_outbound_request("window/showDocument",
          {uri: uri, external: external, takeFocus: take_focus, selection: selection})
      else
        send_outbound_request("window/showDocument",
          {uri: uri, external: external, takeFocus: take_focus})
      end
    end

    # One entry in a `workspace/configuration` reverse request — a
    # (scopeUri, section) pair where either side may be `nil` per the
    # LSP spec.
    alias ConfigurationItem = NamedTuple(scopeUri: String?, section: String?)

    # `workspace/configuration` reverse REQUEST. v1 is fire-and-forget:
    # we don't yet correlate the response back to the caller, so any
    # configuration the server needs at startup must come through
    # `workspace/didChangeConfiguration` instead. Response correlation
    # is TODO.
    def request_configuration(items : Array(ConfigurationItem)) : Nil
      send_outbound_request("workspace/configuration", {items: items})
    end

    # Install the `LogForwarder` so subsequent `Log` entries are
    # mirrored to the client as `window/logMessage` notifications.
    # Binds at Info regardless of the stderr backend's level — the
    # editor output panel is a separate channel and users generally
    # want Warn/Error from the server even when they've turned the
    # stderr log down.
    def attach_client_log_forwarding : Nil
      ::Log.builder.bind(LOG_SOURCE_PATTERN, ::Log::Severity::Info, LogForwarder.new(self))
    end

    # Blocks reading messages from stdin until EOF or `exit`.
    def run : Nil
      Log.info { "crystal-language-server #{CrystalLanguageServer::VERSION} starting (crystal=#{@options.crystal_bin})" }
      while msg = read_next
        handle(msg)
      end
    rescue ex
      Log.error(exception: ex) { "server crashed" }
      raise ex
    end

    private def read_next : JSON::Any?
      @transport.read
    rescue ex : Transport::ParseError
      Log.warn { "transport parse error: #{ex.message}" }
      nil
    end

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------

    # Public for test entry; in production it's only called from `run`.
    # The semantics match the LSP spec: requests (with `id`) dispatch
    # asynchronously, notifications run synchronously on the caller's
    # fiber.
    def handle(msg : JSON::Any) : Nil
      method = msg["method"]?.try(&.as_s)
      id = msg["id"]?
      params = msg["params"]? || JSON::Any.new({} of String => JSON::Any)

      if method.nil?
        # A response to a server-originated request — we don't send any
        # yet, so just ignore.
        return
      end

      if id
        # Spawn a fiber per request so a slow compiler invocation on one
        # handler (hover, diagnostics) doesn't block another on the same
        # keystroke. Transport.write is mutex-guarded so replies can't
        # interleave.
        spawn dispatch_request_async(method, params, id)
      else
        # Notifications mutate state (didChange) or are trivial. Running
        # them synchronously preserves ordering guarantees the LSP spec
        # assumes — a textDocument/hover that arrives after a didChange
        # must see the post-change buffer.
        dispatch_notification(method, params)
      end
    end

    private def dispatch_request_async(method : String, params : JSON::Any, id : JSON::Any) : Nil
      token = CancelToken.new
      id_key = id.to_json
      register_cancel(id_key, token)
      begin
        @transport.write build_reply(method, params, id, token)
      ensure
        unregister_cancel(id_key)
      end
    end

    # Build the JSON-RPC reply for one request. Factored out so the
    # cancellation check lives next to both the success and rescue
    # paths — a cancel that lands while a handler is still running
    # must win over whatever result it eventually produced.
    private def build_reply(method : String, params : JSON::Any, id : JSON::Any, token : CancelToken)
      result = dispatch_request(method, params, token)
      return cancelled_error(id) if token.cancelled?
      Protocol.response(id, result)
    rescue ex : NotImplementedError
      Protocol.error(id, Protocol::ErrorCodes::METHOD_NOT_FOUND, ex.message || "method not found")
    rescue ex
      Log.error(exception: ex) { "error in #{method}" }
      return cancelled_error(id) if token.cancelled?
      Protocol.error(id, Protocol::ErrorCodes::INTERNAL_ERROR, ex.message || "internal error")
    end

    private def cancelled_error(id : JSON::Any)
      Protocol.error(id, Protocol::ErrorCodes::REQUEST_CANCELLED, "request cancelled")
    end

    private def register_cancel(id_key : String, token : CancelToken) : Nil
      @cancellations_mutex.synchronize { @cancellations[id_key] = token }
    end

    private def unregister_cancel(id_key : String) : Nil
      @cancellations_mutex.synchronize { @cancellations.delete(id_key) }
    end

    private def cancel_request(id_key : String) : Nil
      token = @cancellations_mutex.synchronize { @cancellations[id_key]? }
      token.try(&.cancel)
    end

    private def dispatch_request(method : String, params : JSON::Any, cancel_token : CancelToken)
      case method
      when "initialize"         then Handlers::Lifecycle.handle_initialize(self, params)
      when "shutdown"           then (@shutdown_requested = true; nil)
      when "textDocument/hover" then Handlers::Hover.handle(@workspace, params, cancel_token)
      when "textDocument/definition",
           "textDocument/declaration"
        Handlers::Definition.handle(@workspace, params)
      when "textDocument/implementation"
        Handlers::Implementation.handle(@workspace, params)
      when "textDocument/typeDefinition"
        Handlers::TypeDefinition.handle(@workspace, params)
      when "textDocument/formatting"
        Handlers::Formatting.handle(@workspace, params)
      when "textDocument/rangeFormatting"
        Handlers::RangeFormatting.handle(@workspace, params)
      when "textDocument/onTypeFormatting"
        Handlers::OnTypeFormatting.handle(@workspace, params)
      when "textDocument/documentSymbol"
        Handlers::DocumentSymbol.handle(@workspace, params)
      when "textDocument/completion" then Handlers::Completion.handle(@workspace, params)
      when "completionItem/resolve"  then Handlers::Completion.resolve(@workspace, params)
      when "textDocument/diagnostic" then Handlers::PullDiagnostics.handle(@workspace, params, cancel_token)
      when "textDocument/semanticTokens/full"
        Handlers::SemanticTokens.handle(@workspace, params)
      when "textDocument/semanticTokens/full/delta"
        Handlers::SemanticTokens.handle_delta(@workspace, params)
      when "textDocument/semanticTokens/range"
        Handlers::SemanticTokens.handle_range(@workspace, params)
      when "textDocument/foldingRange"
        Handlers::FoldingRange.handle(@workspace, params)
      when "workspace/symbol"          then Handlers::WorkspaceSymbol.handle(@workspace, params)
      when "textDocument/documentLink" then Handlers::DocumentLink.handle(@workspace, params)
      when "textDocument/documentHighlight"
        Handlers::DocumentHighlight.handle(@workspace, params)
      when "textDocument/signatureHelp"
        Handlers::SignatureHelp.handle(@workspace, params)
      when "textDocument/inlayHint"
        Handlers::InlayHints.handle(@workspace, params)
      when "textDocument/references"
        Handlers::References.handle(@workspace, params)
      when "textDocument/rename"
        Handlers::Rename.handle(@workspace, params)
      when "textDocument/prepareRename"
        Handlers::PrepareRename.handle(@workspace, params)
      when "textDocument/selectionRange"
        Handlers::SelectionRange.handle(@workspace, params)
      when "textDocument/codeAction"
        Handlers::CodeAction.handle(@workspace, params)
      when "textDocument/codeLens"
        Handlers::CodeLens.handle(@workspace, params)
      when "codeLens/resolve"
        Handlers::CodeLens.resolve(@workspace, params)
      when "textDocument/prepareCallHierarchy"
        Handlers::CallHierarchy.prepare(@workspace, params)
      when "callHierarchy/incomingCalls"
        Handlers::CallHierarchy.incoming_calls(@workspace, params)
      when "callHierarchy/outgoingCalls"
        Handlers::CallHierarchy.outgoing_calls(@workspace, params)
      when "textDocument/prepareTypeHierarchy"
        Handlers::TypeHierarchy.prepare(@workspace, params)
      when "typeHierarchy/supertypes"
        Handlers::TypeHierarchy.supertypes(@workspace, params)
      when "typeHierarchy/subtypes"
        Handlers::TypeHierarchy.subtypes(@workspace, params)
      when "workspace/executeCommand"
        Handlers::WorkspaceChanges.execute_command(@workspace, params)
      when "textDocument/willSaveWaitUntil"
        Handlers::WillSave.wait_until(@workspace, params)
      else
        raise NotImplementedError.new("method not implemented: #{method}")
      end
    end

    private def dispatch_notification(method : String, params : JSON::Any) : Nil
      case method
      when "initialized"
        Handlers::Lifecycle.handle_initialized(self, params)
      when "exit"
        Log.info { "exit (shutdown_requested=#{@shutdown_requested})" }
        exit(@shutdown_requested ? 0 : 1)
      when "textDocument/didOpen"
        uri = Handlers::TextSync.did_open(@workspace, params)
        @diagnostics.schedule(uri, DiagnosticsEvent::Open)
      when "textDocument/didChange"
        if uri = Handlers::TextSync.did_change(@workspace, params)
          @diagnostics.schedule(uri, DiagnosticsEvent::Change)
        end
      when "textDocument/didSave"
        if uri = Handlers::TextSync.did_save(@workspace, params)
          @diagnostics.schedule(uri, DiagnosticsEvent::Save)
        end
      when "textDocument/didClose"
        uri = Handlers::TextSync.did_close(@workspace, params)
        @transport.write Protocol.notification(
          "textDocument/publishDiagnostics",
          {uri: uri, diagnostics: [] of JSON::Any},
        )
      when "workspace/didChangeConfiguration"
        Handlers::WorkspaceChanges.did_change_configuration(@workspace, params)
      when "workspace/didChangeWatchedFiles"
        Handlers::WorkspaceChanges.did_change_watched_files(@workspace, params)
      when "workspace/didCreateFiles"
        Handlers::WorkspaceChanges.did_create_files(@workspace, params)
      when "workspace/didRenameFiles"
        Handlers::WorkspaceChanges.did_rename_files(@workspace, params)
      when "workspace/didDeleteFiles"
        Handlers::WorkspaceChanges.did_delete_files(@workspace, params)
      when "$/cancelRequest"
        # LSP guarantees the id is Int | String; JSON::Any#to_json is a
        # canonical round-trip for either, which matches how we keyed
        # the token on registration.
        if cancel_id = params["id"]?
          cancel_request(cancel_id.to_json)
        end
      when "$/setTrace", "$/logTrace"
        # silently accepted
      else
        Log.debug { "unhandled notification: #{method}" }
      end
    end
  end
end
