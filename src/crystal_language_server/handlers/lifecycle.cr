module CrystalLanguageServer
  module Handlers
    module Lifecycle
      extend self

      # Server capabilities advertised during `initialize`. Keep this in
      # one place so adding a handler is a single-site change — adding a
      # method here must be paired with a registration in Server's
      # dispatch table.
      def capabilities
        {
          textDocumentSync: {
            openClose:         true,
            change:            Protocol::TextDocumentSyncKind::INCREMENTAL,
            willSaveWaitUntil: true,
            save:              {includeText: false},
          },
          hoverProvider:                    true,
          definitionProvider:               true,
          declarationProvider:              true,
          implementationProvider:           true,
          typeDefinitionProvider:           true,
          documentFormattingProvider:       true,
          documentRangeFormattingProvider:  true,
          documentOnTypeFormattingProvider: {
            firstTriggerCharacter: "\n",
            moreTriggerCharacter:  [] of String,
          },
          documentSymbolProvider:  true,
          workspaceSymbolProvider: true,
          completionProvider:      {
            triggerCharacters:   [".", ":", "@", "#"],
            allCommitCharacters: [".", "(", ")", "[", "]", ",", ";", " "],
            resolveProvider:     true,
            completionItem:      {labelDetailsSupport: true},
          },
          diagnosticProvider: {
            interFileDependencies: false,
            workspaceDiagnostics:  false,
          },
          semanticTokensProvider: {
            legend: {
              tokenTypes:     SemanticTokens::TOKEN_TYPES,
              tokenModifiers: SemanticTokens::TOKEN_MODIFIERS,
            },
            range: true,
            full:  {delta: true},
          },
          foldingRangeProvider:      true,
          documentLinkProvider:      {resolveProvider: false},
          documentHighlightProvider: true,
          signatureHelpProvider:     {triggerCharacters: ["(", ","], retriggerCharacters: [")"]},
          inlayHintProvider:         {resolveProvider: false},
          referencesProvider:        true,
          renameProvider:            {prepareProvider: true},
          selectionRangeProvider:    true,
          codeActionProvider:        {
            codeActionKinds: [
              CodeAction::KIND_QUICKFIX,
              CodeAction::KIND_SOURCE_FIXALL,
              CodeAction::KIND_SOURCE_ORGANIZE_IMPORTS,
            ],
            resolveProvider: false,
          },
          codeLensProvider:       {resolveProvider: true},
          callHierarchyProvider:  true,
          typeHierarchyProvider:  true,
          executeCommandProvider: {commands: WorkspaceChanges::COMMANDS},
          workspace:              {
            workspaceFolders: {
              supported:           true,
              changeNotifications: true,
            },
            fileOperations: {
              didCreate: {filters: [{pattern: {glob: "**/*.cr"}}]},
              didRename: {filters: [{pattern: {glob: "**/*.cr"}}]},
              didDelete: {filters: [{pattern: {glob: "**/*.cr"}}]},
            },
          },
        }
      end

      def handle_initialize(server : Server, params : JSON::Any)
        ws = server.workspace
        ws.client_capabilities = params["capabilities"]?

        # Once `initialize` lands the transport is owned by a client
        # actively reading, so it's now safe to mirror logs back as
        # `window/logMessage` notifications.
        server.attach_client_log_forwarding

        # Attach the progress reporter *before* setting root_path —
        # `root_path=` kicks off the warm pass, which the reporter
        # observes. Skip the reporter entirely when the client hasn't
        # advertised window.workDoneProgress support; sending a token
        # the client can't handle spams warnings in its log panel.
        if client_supports_work_done_progress?(params)
          reporter = ProgressReporter.new(server.transport, "crystal-index-warm", "Indexing Crystal workspace")
          server.send_outbound_request("window/workDoneProgress/create", {token: reporter.token})
          ws.progress_reporter = reporter
        end

        if root_uri = params["rootUri"]?.try(&.as_s?)
          ws.root_path = DocumentUri.to_path(root_uri)
        elsif root_path = params["rootPath"]?.try(&.as_s?)
          ws.root_path = root_path
        end

        {
          capabilities: capabilities,
          serverInfo:   {name: "crystal-language-server", version: CrystalLanguageServer::VERSION},
        }
      end

      # Register a file watcher for `**/*.cr` so the client reliably
      # fires `workspace/didChangeWatchedFiles` on external edits. The
      # workspace/fileOperations capability covers explorer-driven
      # renames; this covers everything else (git checkouts, external
      # tools writing files, etc.).
      def handle_initialized(server : Server, params : JSON::Any) : Nil
        server.send_outbound_request("client/registerCapability", {
          registrations: [{
            id:              "crystal-watched-files",
            method:          "workspace/didChangeWatchedFiles",
            registerOptions: {
              watchers: [{globPattern: "**/*.cr"}],
            },
          }],
        })
      end

      private def client_supports_work_done_progress?(params : JSON::Any) : Bool
        params.dig?("capabilities", "window", "workDoneProgress").try(&.as_bool?) == true
      end
    end
  end
end
