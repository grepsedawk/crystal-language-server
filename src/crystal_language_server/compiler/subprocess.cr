require "process"

module CrystalLanguageServer
  module Compiler
    # Shells out to the `crystal` CLI for every semantic operation.
    # Slow (forks a process per request) but rock-solid — it's the
    # compiler the user already has installed, versioned with their
    # system. This is the default provider because any drift between
    # Crystal releases is absorbed by the CLI tool's own stability
    # guarantees.
    #
    # See `Embedded` for the in-process alternative.
    class Subprocess < Provider
      # Wall-clock ceiling for `crystal tool` invocations driven by
      # interactive requests (hover, completion, goto). A dep graph
      # that takes longer than this to type-check probably isn't going
      # to give us useful cursor info in a user-interactive window —
      # better to fall through to scanner-based fallbacks immediately
      # and keep the editor responsive.
      TOOL_TIMEOUT = 10.seconds

      # Build diagnostics can reasonably take longer; they run
      # debounced in the background.
      BUILD_TIMEOUT = 15.seconds

      def initialize(@crystal_bin : String = "crystal")
      end

      protected def context_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        run_cursor_tool("context", file_path, source, line, column, cancel_token)
      end

      protected def implementations_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        run_cursor_tool("implementations", file_path, source, line, column, cancel_token)
      end

      def format(source : String) : String?
        result = run_io(["tool", "format", "--no-color", "-"], stdin: source, timeout: TOOL_TIMEOUT)
        return nil unless result
        result.success? ? result.stdout : nil
      end

      protected def build_diagnostics_impl(file_path : String, source : String, cancel_token : CancelToken?) : Array(BuildError)
        raw = run_with_source(file_path, source) do |path|
          run_io(["build", "--no-codegen", "--no-color", "-f", "json", path], timeout: BUILD_TIMEOUT, cancel_token: cancel_token)
        end
        return [] of BuildError unless raw
        parse_build_errors(raw)
      end

      # --- internal ----------------------------------------------------

      private def run_cursor_tool(subcommand : String, file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        # Fast path: buffer matches disk, shard entrypoint exists. Compile
        # through the entrypoint so requires/macros resolve; keep the
        # cursor on the user's file.
        if !file_path.empty? && File.exists?(file_path) && File.read(file_path) == source
          entry = EntrypointResolver.for_file(file_path)
          if entry && entry != file_path
            result = run_io(["tool", subcommand, "-f", "json", "--no-color",
                             "--cursor", "#{file_path}:#{line}:#{column}", entry], timeout: TOOL_TIMEOUT, cancel_token: cancel_token)
            # If the entrypoint run timed out (nil), the single-file
            # retry below would almost certainly time out too on the
            # same source — and the user would wait ~2× TOOL_TIMEOUT
            # before getting a scanner fallback. Bail out fast instead.
            return nil if result.nil?
            if (json = parse_tool_output(result)) && useful_tool_result?(json)
              return json
            end
          end
        end

        return nil if cancel_token.try(&.cancelled?)

        # Slow path: single-file compile (possibly via tempfile for dirty
        # buffers).
        result = run_with_source(file_path, source) do |path|
          run_io(["tool", subcommand, "-f", "json", "--no-color",
                  "--cursor", "#{path}:#{line}:#{column}", path], timeout: TOOL_TIMEOUT, cancel_token: cancel_token)
        end
        result.try { |r| parse_tool_output(r) }
      end

      private def useful_tool_result?(json : JSON::Any) : Bool
        json["status"]?.try(&.as_s?) == "ok"
      end

      private def parse_tool_output(result : RunResult) : JSON::Any?
        return nil unless result.success?
        return nil if result.stdout.empty?
        JSON.parse(result.stdout)
      rescue JSON::ParseException
        nil
      end

      private def parse_build_errors(result : RunResult) : Array(BuildError)
        return [] of BuildError if result.success?

        # `crystal build -f json` writes the error array to STDERR, not
        # STDOUT. This surprised me the first time; the CLI reserves
        # STDOUT for positive output (none, with --no-codegen) and
        # sends diagnostics to STDERR so they don't pollute pipelines
        # downstream of `crystal build`.
        output = result.stderr.strip
        output = result.stdout.strip if output.empty?
        return [] of BuildError if output.empty?

        Array(BuildError).from_json(output)
      rescue JSON::ParseException
        [
          BuildError.new(
            file: "",
            line: 1,
            column: 1,
            size: nil,
            message: "crystal build failed: #{result.stderr.presence || result.stdout}",
          ),
        ]
      end

      private def run_with_source(file_path : String, source : String, &block : String -> RunResult?) : RunResult?
        if file_path.empty? || !File.exists?(file_path) || File.read(file_path) != source
          dir = File.dirname(file_path.empty? ? Dir.current : file_path)
          Dir.mkdir_p(dir) unless File.exists?(dir)
          # Always .cr: an empty file_path means the caller doesn't have
          # a user-facing path, but the compiler still needs to see a
          # Crystal-shaped filename to recognise the source.
          ext = file_path.empty? ? ".cr" : (File.extname(file_path).presence || ".cr")
          tempfile = File.tempfile("crystal-language-server-", ext)
          begin
            File.write(tempfile.path, source)
            block.call(tempfile.path)
          ensure
            tempfile.delete rescue nil
          end
        else
          block.call(file_path)
        end
      rescue ex
        Log.warn { "crystal tool invocation failed: #{ex.message}" }
        nil
      end

      # Spawn the crystal process and return a RunResult, or nil if the
      # timeout expires first (in which case the child is SIGKILL'd), or
      # nil if the caller's cancel token trips (ditto SIGKILL). The three-
      # way select is the single point that binds LSP request lifecycle
      # to the compiler child's lifecycle.
      private def run_io(args : Array(String), stdin : String? = nil, timeout : Time::Span = BUILD_TIMEOUT, cancel_token : CancelToken? = nil) : RunResult?
        # Check before spawn: if the request was cancelled in the time
        # between registration and the subprocess call, don't even pay
        # the fork cost.
        return nil if cancel_token.try(&.cancelled?)

        out_io = IO::Memory.new
        err_io = IO::Memory.new

        Log.debug { "exec: #{@crystal_bin} #{args.join(" ")}" }
        input_io : IO | Process::Redirect = stdin ? IO::Memory.new(stdin) : Process::Redirect::Close
        process = Process.new(@crystal_bin, args, input: input_io, output: out_io, error: err_io)

        done = Channel(Process::Status).new(1)
        spawn do
          status = process.wait
          done.send(status)
        rescue
          # already reaped
        end

        # A never-firing channel stands in when no token is supplied so
        # the select stays a single expression — cheaper than branching
        # on two different select shapes.
        cancel_channel = cancel_token.try(&.channel) || Channel(Nil).new

        select
        when status = done.receive
          RunResult.new(status, out_io.to_s, err_io.to_s)
        when timeout(timeout)
          Log.warn { "crystal tool timed out after #{timeout.total_seconds}s: #{args.join(" ")}" }
          kill_process(process)
          nil
        when cancel_channel.receive?
          Log.debug { "crystal tool cancelled: #{args.join(" ")}" }
          kill_process(process)
          nil
        end
      end

      private def kill_process(process : Process) : Nil
        process.signal(Signal::KILL)
      rescue
        # Already reaped or permission denied — either way, nothing we
        # can do, and the client has moved on.
      end

      # Small record type so we can share the subprocess plumbing
      # without exposing `Process::Status` upward.
      private struct RunResult
        getter status : Process::Status
        getter stdout : String
        getter stderr : String

        def initialize(@status, @stdout, @stderr)
        end

        def success? : Bool
          @status.success?
        end
      end
    end
  end
end
