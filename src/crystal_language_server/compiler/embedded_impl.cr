# In-process Crystal compiler adapter. Only loaded when
# CRYSTAL_SOURCE_PATH is set at build time — see embedded.cr.
#
# We load the compiler via its own `compiler/requires` umbrella
# because that file knows the correct internal load order
# (Annotatable → Program → Compiler → tools…). Hand-picking
# individual modules trips on undefined constants.
require "compiler/requires"

module CrystalLanguageServer
  module Compiler
    class Embedded < Provider
      # Compiler writes progress + warnings to its own stdout/stderr,
      # which default to the process STDOUT/STDERR — that collides
      # with the LSP's JSON-RPC channel.
      @stdout_sink : IO::Memory = IO::Memory.new
      @stderr_sink : IO::Memory = IO::Memory.new

      # One-entry compile-result memo keyed on (first source filename,
      # source hash). Covers the common "hover then goto on the same
      # keystroke" case where two cursor tools would otherwise pay for
      # the same compile twice.
      private record CompileMemo, key : {String, UInt64}, result : ::Crystal::Compiler::Result
      @memo : CompileMemo? = nil
      @memo_mutex = Mutex.new

      def initialize
        # In-process compiler looks up CRYSTAL_PATH via ENV; the
        # `crystal` binary bakes it in at build time, but a host
        # binary built separately has to discover it once at startup.
        if !ENV["CRYSTAL_PATH"]? && (path = self.class.resolve_crystal_path)
          ENV["CRYSTAL_PATH"] = path
        end
      end

      def self.resolve_crystal_path : String?
        return ENV["CRYSTAL_PATH"]? if ENV["CRYSTAL_PATH"]?
        stdout_io = IO::Memory.new
        status = Process.run("crystal", ["env", "CRYSTAL_PATH"], output: stdout_io, error: Process::Redirect::Close)
        return nil unless status.success?
        stdout_io.to_s.strip.presence
      rescue ex
        Log.debug(exception: ex) { "embedded: failed to resolve CRYSTAL_PATH via crystal env" }
        nil
      end

      protected def context_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        run_cursor_tool(:context, file_path, source, line, column, cancel_token)
      end

      protected def implementations_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        run_cursor_tool(:implementations, file_path, source, line, column, cancel_token)
      end

      # Batch override: compile once, visit N times. The difference
      # between this and the base `contexts_batch` is that the base
      # would pay for a full compile per cursor even with caching warm
      # (different line/col → cache miss). Here we touch the expensive
      # compile exactly once per source version.
      def contexts_batch(file_path : String, source : String, cursors : Array({Int32, Int32})) : Hash({Int32, Int32}, Hash(String, String))
        return super(file_path, source, cursors) if cursors.empty?

        sources = build_sources(file_path, source)
        return super(file_path, source, cursors) if sources.empty?

        result = run_compile(sources)
        compiler_result = result.as?(::Crystal::Compiler::Result)
        return super(file_path, source, cursors) unless compiler_result

        out = {} of {Int32, Int32} => Hash(String, String)
        cursors.each do |(line, col)|
          target = ::Crystal::Location.new(file_path, line, col)
          visitor_result = ::Crystal::ContextVisitor.new(target).process(compiler_result)
          json = JSON.parse(visitor_result.to_json)
          if types = contexts_to_types(json)
            out[{line, col}] = types
          end
        rescue ex
          Log.warn(exception: ex) { "embedded contexts_batch failed at #{line}:#{col}" }
        end
        out
      end

      def format(source : String) : String?
        ::Crystal.format(source)
      rescue ::Crystal::CodeError
        nil
      end

      protected def build_diagnostics_impl(file_path : String, source : String, cancel_token : CancelToken?) : Array(BuildError)
        sources = build_sources(file_path, source)
        return [] of BuildError if sources.empty?
        return [] of BuildError if cancel_token.try(&.cancelled?)

        # Compile itself can't be aborted mid-run (the compiler holds
        # the fiber through native code). The best we can do is check
        # on either side: skip if already cancelled, and drop the
        # result if cancellation happened while we were busy.
        case result = run_compile(sources)
        when ::Crystal::CodeError then errors_from_exception(result)
        else                           [] of BuildError
        end
      end

      # ------------------------------------------------------------------

      # Pick a compile target. Clean buffer inside a shard → compile the
      # entrypoint so requires/macros resolve. Otherwise compile the
      # buffer directly, keeping the real filename so goto targets
      # never leak a tempfile path.
      private def build_sources(file_path : String, source : String) : Array(::Crystal::Compiler::Source)
        return [] of ::Crystal::Compiler::Source if file_path.empty?

        entry = EntrypointResolver.for_file(file_path)
        if entry && entry != file_path && disk_matches?(file_path, source)
          entry_source = File.read(entry) rescue return [::Crystal::Compiler::Source.new(file_path, source)]
          [::Crystal::Compiler::Source.new(entry, entry_source)]
        else
          [::Crystal::Compiler::Source.new(file_path, source)]
        end
      end

      private def disk_matches?(file_path : String, source : String) : Bool
        # Short-circuit on size: avoids reading the whole file for
        # the common dirty-buffer case where the user has typed into
        # the LSP's copy but hasn't saved.
        info = File.info?(file_path)
        return false unless info
        return false unless info.size == source.bytesize
        (File.read(file_path) rescue return false) == source
      end

      private def run_cursor_tool(tool : Symbol, file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        sources = build_sources(file_path, source)
        return nil if sources.empty?
        return nil if cancel_token.try(&.cancelled?)

        result = run_compile(sources)
        if result.is_a?(::Crystal::CodeError)
          Log.debug { "embedded #{tool}: compile error at #{sources.first.filename}: #{result.message}" }
        end

        compiler_result = result.as?(::Crystal::Compiler::Result)
        return nil unless compiler_result

        # Cancel between memo lookup / compile and the visitor pass.
        # Mid-compile is not abortable; this is the best seam we have.
        return nil if cancel_token.try(&.cancelled?)

        target = ::Crystal::Location.new(file_path, line, column)
        tool_result = case tool
                      when :context         then ::Crystal::ContextVisitor.new(target).process(compiler_result)
                      when :implementations then ::Crystal::ImplementationsVisitor.new(target).process(compiler_result)
                      end
        return nil unless tool_result
        JSON.parse(tool_result.to_json)
      rescue ex
        Log.warn(exception: ex) { "embedded #{tool} failed" }
        nil
      end

      # Returns Compiler::Result on success, the CodeError on a
      # catchable compile error, or nil on anything else.
      private def run_compile(sources : Array(::Crystal::Compiler::Source))
        key = {sources.first.filename, sources.first.code.hash}
        @memo_mutex.synchronize do
          if (memo = @memo) && memo.key == key
            return memo.result
          end
        end

        compiler = ::Crystal::Compiler.new
        compiler.no_codegen = true
        # Cursor tools expect the post-cleanup AST shape — visitors
        # were written against that, not the pre-cleanup form.
        compiler.no_cleanup = false
        compiler.color = false
        compiler.stdout = @stdout_sink
        compiler.stderr = @stderr_sink
        @stdout_sink.clear
        @stderr_sink.clear

        result = compiler.compile(sources, output_filename_for(sources))
        @memo_mutex.synchronize { @memo = CompileMemo.new(key, result) }
        result
      rescue ex : ::Crystal::CodeError
        ex
      rescue ex
        Log.warn(exception: ex) { "embedded compile failed" }
        nil
      end

      # Compiler#compile requires an output filename even with
      # no_codegen — it's used for the .bc cache path. Tempdir keeps
      # it off the user's shard; source-hash keeps two concurrent
      # compiles from stomping each other.
      private def output_filename_for(sources : Array(::Crystal::Compiler::Source)) : String
        base = File.basename(sources.first.filename, ".cr")
        File.join(Dir.tempdir, "crystal-lsp-#{base}-#{sources.first.code.hash.to_s(16)}")
      end

      # The compiler's own `to_json` emits an array whose element
      # schema matches BuildError byte-for-byte. Round-trip through
      # that serializer rather than re-probing fields via responds_to?.
      private def errors_from_exception(ex : ::Crystal::CodeError) : Array(BuildError)
        Array(BuildError).from_json(ex.to_json)
      rescue JSON::ParseException
        [BuildError.new(file: "", line: nil, column: nil, size: nil, message: ex.message || "compile error")]
      end
    end
  end
end
