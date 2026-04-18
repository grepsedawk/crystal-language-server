module CrystalLanguageServer
  module Compiler
    # The abstract surface every compiler adapter implements. Keep this
    # file deliberately minimal — each method here is a seam that must
    # be mirrored by every adapter, so adding one is a real cost. If a
    # handler needs something new, grow this interface, implement in
    # both Subprocess and Embedded, and document the contract.
    #
    # Return shapes intentionally mirror what `crystal tool <cmd> -f
    # json` produces today, so the adapters can share callers
    # unchanged. That's a compatibility choice, not an architectural
    # one — we can normalize later if it becomes limiting.
    abstract class Provider
      # Subclasses implement the real work. Public-facing `context` and
      # `implementations` wrap these with a shared cache below, so every
      # handler benefits without each adapter re-rolling the cache
      # bookkeeping.
      protected abstract def context_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken?) : JSON::Any?
      protected abstract def implementations_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken?) : JSON::Any?
      protected abstract def build_diagnostics_impl(file_path : String, source : String, cancel_token : CancelToken?) : Array(BuildError)

      # Format Crystal source. Returns the formatted text, or nil when
      # formatting fails (usually because the input has a syntax
      # error).
      abstract def format(source : String) : String?

      # Run diagnostics over a source file. Returns an array of
      # compile errors with file/line/column/size/message — same shape
      # Crystal's `crystal build -f json` uses.
      #
      # Cached per (file, source_hash). Push (publishDiagnostics) and
      # pull (textDocument/diagnostic) typically fire on the same edit;
      # the cache means we compile once and serve both.
      def build_diagnostics(file_path : String, source : String, cancel_token : CancelToken? = nil) : Array(BuildError)
        @diagnostics_cache.fetch(file_path, source) do
          next [] of BuildError if cancel_token.try(&.cancelled?)
          build_diagnostics_impl(file_path, source, cancel_token)
        end
      end

      # Run the `context` tool. Returns the parsed JSON shape:
      #   {"status": "ok"|"failed", "message": "...", "contexts": [...]}
      # or nil on invocation failure.
      #
      # Cached across handlers keyed on (file, source_hash, cursor).
      # Hover, completion, and inlay hints on the same keystroke all
      # share one real compile.
      def context(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        @result_cache.fetch(:context, file_path, source, line, column) do
          next nil if cancel_token.try(&.cancelled?)
          context_impl(file_path, source, line, column, cancel_token)
        end
      end

      # Run the `implementations` tool. Returns the parsed JSON shape:
      #   {"status": "ok"|"failed", "message": "...", "implementations": [...]}
      # or nil on invocation failure.
      def implementations(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
        @result_cache.fetch(:implementations, file_path, source, line, column) do
          next nil if cancel_token.try(&.cancelled?)
          implementations_impl(file_path, source, line, column, cancel_token)
        end
      end

      # Collapse the first `contexts` entry into a flat name -> type
      # string map. Returns nil when no consistent types were found.
      # Default implementation built on top of `context`.
      def context_types(file_path : String, source : String, line : Int32, column : Int32) : Hash(String, String)?
        contexts_to_types(context(file_path, source, line, column))
      end

      # Batch variant: one compile, many cursors. Embedded mode
      # overrides this to run the ContextVisitor N times against a
      # single memoized compile; subprocess mode falls back to N
      # individual calls (already cached, so a warm cache is instant).
      def contexts_batch(file_path : String, source : String, cursors : Array({Int32, Int32})) : Hash({Int32, Int32}, Hash(String, String))
        out = {} of {Int32, Int32} => Hash(String, String)
        cursors.each do |(line, col)|
          if types = context_types(file_path, source, line, col)
            out[{line, col}] = types
          end
        end
        out
      end

      protected def contexts_to_types(json : JSON::Any?) : Hash(String, String)?
        return nil unless json
        return nil unless json["status"]?.try(&.as_s?) == "ok"
        contexts = json["contexts"]?.try(&.as_a?)
        return nil unless contexts && !contexts.empty?

        head = contexts.first.as_h
        rest = contexts[1..]
        result = {} of String => String
        head.each do |name, type|
          type_s = type.as_s
          consistent = rest.all? { |c| c.as_h[name]?.try(&.as_s) == type_s }
          result[name] = type_s if consistent
        end
        result
      end

      @result_cache = ResultCache.new
      @diagnostics_cache = DiagnosticsCache.new

      # Small LRU-ish cache keyed on (tool, file, source_hash, line, col).
      # Per-file single entry: when the source changes we drop the old
      # entry for that file. Tiny and thread-safe.
      private class ResultCache
        MAX_ENTRIES = 32

        private record Entry, tool : Symbol, file : String, source_hash : UInt64, line : Int32, column : Int32, value : JSON::Any

        def initialize
          @mutex = Mutex.new
          @entries = [] of Entry
        end

        def fetch(tool : Symbol, file : String, source : String, line : Int32, column : Int32, & : -> JSON::Any?) : JSON::Any?
          hash = source.hash
          @mutex.synchronize do
            @entries.each do |e|
              if e.tool == tool && e.file == file && e.source_hash == hash && e.line == line && e.column == column
                return e.value
              end
            end
            # Drop any stale entries for this (tool, file) with a different hash.
            @entries.reject! { |e| e.tool == tool && e.file == file && e.source_hash != hash }
          end

          value = yield
          return nil unless value

          @mutex.synchronize do
            @entries << Entry.new(tool, file, hash, line, column, value)
            while @entries.size > MAX_ENTRIES
              @entries.shift
            end
          end
          value
        end

        # Called when a document's content changes to proactively drop
        # cached results for the old source hash. Not strictly needed
        # (hash mismatch would miss on next fetch anyway), but bounds
        # memory for files that thrash.
        def invalidate_file(file : String) : Nil
          @mutex.synchronize do
            @entries.reject! { |e| e.file == file }
          end
        end
      end

      def invalidate_cache(file_path : String) : Nil
        @result_cache.invalidate_file(file_path)
        @diagnostics_cache.invalidate(file_path)
      end

      # One entry per file — the latest source hash wins. Pull (LSP
      # 3.17 textDocument/diagnostic) and push (publishDiagnostics)
      # both call build_diagnostics; without this cache they'd each
      # spend a full compile on identical input. Capped so a long
      # session that opens many files doesn't grow without bound.
      private class DiagnosticsCache
        MAX_ENTRIES = 64

        private record Entry, source_hash : UInt64, errors : Array(BuildError)

        def initialize
          @mutex = Mutex.new
          # Hash preserves insertion order, so deleting and re-inserting
          # on hit gives us LRU eviction for free.
          @entries = {} of String => Entry
        end

        def fetch(file : String, source : String, & : -> Array(BuildError)) : Array(BuildError)
          hash = source.hash
          @mutex.synchronize do
            cached = @entries[file]?
            if cached && cached.source_hash == hash
              @entries.delete(file)
              @entries[file] = cached
              return cached.errors
            end
          end

          errors = yield
          @mutex.synchronize do
            @entries.delete(file)
            @entries[file] = Entry.new(hash, errors)
            while @entries.size > MAX_ENTRIES
              @entries.delete(@entries.first_key)
            end
          end
          errors
        end

        def invalidate(file : String) : Nil
          @mutex.synchronize { @entries.delete(file) }
        end
      end
    end

    # Shared error type returned by `build_diagnostics`. JSON-compatible
    # with Crystal's own `-f json` output.
    struct BuildError
      include JSON::Serializable

      UNUSED_PATTERN     = /\b(?:unused|never used|unreachable)\b/i
      DEPRECATED_PATTERN = /\bdeprecated\b/i

      getter file : String
      getter line : Int32?
      getter column : Int32?
      getter size : Int32?
      getter message : String

      def initialize(@file, @line, @column, @size, @message)
      end

      # Convert to an LSP Diagnostic anchored against `current_path`.
      # Errors that originate in another file (a required dep that
      # failed to compile) collapse to `(0,0)` in the current buffer
      # with the foreign path inlined into the message — there's no
      # publish channel for cross-file diagnostics under the per-uri
      # debouncer.
      def to_diagnostic(current_path : String) : Protocol::Diagnostic
        in_this_file = file == current_path || file.empty?
        l = (line || 1) - 1
        c = (column || 1) - 1
        sz = size || 1

        range = if in_this_file
                  LspRange.new(LspPosition.new(l, c), LspPosition.new(l, c + sz))
                else
                  LspRange.new(LspPosition.new(0, 0), LspPosition.new(0, 0))
                end
        msg = in_this_file ? message : "in #{file}:#{line}:#{column} — #{message}"
        Protocol::Diagnostic.new(range, Protocol::DiagnosticSeverity::ERROR, msg, tags: tags_for(message))
      end

      # LSP DiagnosticTag detection against the compiler's message text.
      # Keep the patterns narrow — a false positive dims legitimate
      # errors, which is worse than an unflagged warning.
      private def tags_for(text : String) : Array(Int32)?
        tags = [] of Int32
        tags << Protocol::DiagnosticTag::UNNECESSARY if UNUSED_PATTERN.matches?(text)
        tags << Protocol::DiagnosticTag::DEPRECATED if DEPRECATED_PATTERN.matches?(text)
        tags.empty? ? nil : tags
      end
    end

    # Lookup a shard's root or entrypoint by walking upward from a
    # given path. Both results are cached keyed on the shard.yml's
    # modification time so edits mid-session invalidate naturally.
    module EntrypointResolver
      extend self

      private record CacheEntry, entry : String?, mtime : Time

      @@cache = {} of String => CacheEntry
      @@cache_mutex = Mutex.new

      # Absolute path of the entrypoint file for `path`, or nil if no
      # shard.yml was found or the entrypoint couldn't be determined.
      def for_file(file_path : String) : String?
        shard_root = find_shard_root(file_path)
        return nil unless shard_root

        yml_path = File.join(shard_root, "shard.yml")
        info = File.info?(yml_path)
        return nil unless info

        @@cache_mutex.synchronize do
          cached = @@cache[shard_root]?
          return cached.entry if cached && cached.mtime == info.modification_time
        end

        entry = parse_entrypoint(shard_root)
        @@cache_mutex.synchronize do
          @@cache[shard_root] = CacheEntry.new(entry, info.modification_time)
        end
        entry
      end

      # Directory of the nearest ancestor shard.yml. Accepts a file
      # *or* a directory — matches the old Workspace contract.
      def find_shard_root(path : String) : String?
        dir = File.directory?(path) ? path : File.dirname(path)
        while dir != "/" && !dir.empty?
          return dir if File.exists?(File.join(dir, "shard.yml"))
          parent = File.dirname(dir)
          break if parent == dir
          dir = parent
        end
        nil
      end

      private def parse_entrypoint(shard_root : String) : String?
        yml = File.read(File.join(shard_root, "shard.yml")) rescue return nil

        if match = yml.match(/^\s{4,}main:\s*(\S+)/m)
          candidate = File.expand_path(match[1], shard_root)
          return candidate if File.exists?(candidate)
        end

        if match = yml.match(/^name:\s*(\S+)/m)
          candidate = File.join(shard_root, "src", "#{match[1]}.cr")
          return candidate if File.exists?(candidate)
        end

        nil
      end
    end
  end
end
