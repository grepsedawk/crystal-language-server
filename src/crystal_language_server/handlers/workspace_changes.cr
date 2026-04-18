module CrystalLanguageServer
  module Handlers
    # Handlers for the workspace/* notifications that a well-behaved
    # LSP accepts: configuration pushes, file watcher events, and
    # command execution.
    module WorkspaceChanges
      extend self

      RUN_SPEC_COMMAND    = "crystal.runSpec"
      RUN_FILE_COMMAND    = "crystal.runFile"
      FORMAT_FILE_COMMAND = "crystal.formatFile"

      # Advertised back to the client from `executeCommandProvider`.
      # Clients gate command dispatch on this list — anything not
      # listed here is refused before it reaches the server.
      COMMANDS = [RUN_SPEC_COMMAND, RUN_FILE_COMMAND, FORMAT_FILE_COMMAND]

      # workspace/didChangeConfiguration: clients push full settings
      # blobs here. We don't have configurable runtime options today,
      # but accepting the notification quietly stops the client from
      # warning the user.
      def did_change_configuration(ws : Workspace, params : JSON::Any) : Nil
        Log.debug { "workspace/didChangeConfiguration received" }
      end

      # workspace/didChangeWatchedFiles: the editor saw a .cr change
      # outside our buffers — probably an external `git checkout`.
      # Drop cached scanner results so the next lookup re-reads.
      def did_change_watched_files(ws : Workspace, params : JSON::Any) : Nil
        changes = params["changes"]?.try(&.as_a?) || return
        changes.each do |change|
          uri = change["uri"].as_s
          path = DocumentUri.to_path(uri)
          ws.compiler.invalidate_cache(path)
          # Pick up the on-disk state directly. This both refreshes
          # the per-file scan cache and rebuilds the name-index
          # entries for the path (empty pairs if the file was
          # deleted — remove_file_from_index_locked handles that).
          WorkspaceIndex.reindex_file_from_disk(path)
        end
      end

      # workspace/executeCommand: the client clicked a code-action
      # command or a CodeLens. We dispatch the three run-style
      # commands the test CodeLens emits. Every branch returns nil —
      # commands are fire-and-forget from the LSP's perspective, and
      # the actual subprocess is detached onto a fiber so we never
      # block the request handler.
      def execute_command(ws : Workspace, params : JSON::Any)
        cmd = params["command"]?.try(&.as_s?)
        args = params["arguments"]?.try(&.as_a?) || [] of JSON::Any

        case cmd
        when RUN_SPEC_COMMAND    then run_spec(ws, args)
        when RUN_FILE_COMMAND    then run_file(ws, args)
        when FORMAT_FILE_COMMAND then format_file(ws, args)
        when nil
          Log.warn { "workspace/executeCommand: missing command field" }
        else
          Log.warn { "workspace/executeCommand: unknown command #{cmd.inspect}" }
        end
        nil
      end

      private def run_spec(ws : Workspace, args : Array(JSON::Any)) : Nil
        uri = args[0]?.try(&.as_s?)
        name = args[2]?.try(&.as_s?)
        return unless uri && name
        path = DocumentUri.to_path(uri)
        spawn_crystal(ws, ["spec", path, "-e", name], "crystal spec #{File.basename(path)} -e #{name.inspect}")
      end

      private def run_file(ws : Workspace, args : Array(JSON::Any)) : Nil
        uri = args[0]?.try(&.as_s?)
        return unless uri
        path = DocumentUri.to_path(uri)
        spawn_crystal(ws, ["run", path], "crystal run #{File.basename(path)}")
      end

      private def format_file(ws : Workspace, args : Array(JSON::Any)) : Nil
        uri = args[0]?.try(&.as_s?)
        return unless uri
        path = DocumentUri.to_path(uri)
        spawn_crystal(ws, ["tool", "format", path], "crystal tool format #{File.basename(path)}")
      end

      # Detach onto a fiber: the LSP response has already returned
      # nil, and the subprocess can easily run for minutes (a full
      # `crystal run`). stdout/stderr are captured and forwarded
      # through `Log` — once the outbound-wire `LogForwarder` lands,
      # those lines will be mirrored to the client as
      # `window/logMessage` notifications.
      private def spawn_crystal(ws : Workspace, args : Array(String), label : String) : Nil
        bin = ws.options.crystal_bin
        spawn do
          stdout = IO::Memory.new
          stderr = IO::Memory.new
          status = Process.run(bin, args, output: stdout, error: stderr)
          Log.info { "#{label}: exit=#{status.exit_code}" }
          out_text = stdout.to_s
          err_text = stderr.to_s
          Log.info { "#{label} stdout:\n#{out_text}" } unless out_text.empty?
          Log.warn { "#{label} stderr:\n#{err_text}" } unless err_text.empty?
        rescue ex
          Log.error(exception: ex) { "failed to run: #{label}" }
        end
      end

      # workspace/didCreateFiles, workspace/didRenameFiles,
      # workspace/didDeleteFiles — the client's file-explorer told us
      # about an edit outside our text buffers. The didChangeWatchedFiles
      # notification also fires for most of these, but (a) not all
      # clients send both and (b) rename carries the old+new URI pair,
      # which watched-files can only approximate as delete+create.
      def did_create_files(ws : Workspace, params : JSON::Any) : Nil
        each_file_uri(params) { |path| WorkspaceIndex.reindex_file_from_disk(path) }
        WorkspaceIndex.invalidate_file_listings
      end

      # `reindex_file_from_disk` covers both ends of a rename: for the
      # disappearing `oldUri` the path no longer exists on disk, so
      # `symbols_for` returns nil and the name-index entries for that
      # file get dropped. For `newUri` it walks the fresh content.
      def did_rename_files(ws : Workspace, params : JSON::Any) : Nil
        files = params["files"]?.try(&.as_a?) || return
        files.each do |f|
          old_path = f["oldUri"]?.try(&.as_s?).try { |u| DocumentUri.to_path(u) }
          new_path = f["newUri"]?.try(&.as_s?).try { |u| DocumentUri.to_path(u) }
          if old_path
            WorkspaceIndex.reindex_file_from_disk(old_path)
            ws.compiler.invalidate_cache(old_path)
          end
          if new_path
            WorkspaceIndex.reindex_file_from_disk(new_path)
            ws.compiler.invalidate_cache(new_path)
          end
        end
        WorkspaceIndex.invalidate_file_listings
      end

      def did_delete_files(ws : Workspace, params : JSON::Any) : Nil
        each_file_uri(params) do |path|
          WorkspaceIndex.reindex_file_from_disk(path)
          ws.compiler.invalidate_cache(path)
        end
        WorkspaceIndex.invalidate_file_listings
      end

      private def each_file_uri(params : JSON::Any, & : String ->)
        files = params["files"]?.try(&.as_a?) || return
        files.each do |f|
          uri = f["uri"]?.try(&.as_s?)
          next unless uri
          yield DocumentUri.to_path(uri)
        end
      end
    end
  end
end
