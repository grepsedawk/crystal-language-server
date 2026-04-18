module CrystalLanguageServer
  # Scanner-driven lookup of top-level definitions across a workspace's
  # `.cr` files. This is a fallback for when `crystal tool` can't
  # analyse a file (library code that doesn't compile in isolation,
  # files outside the default compile graph). It's not as accurate as
  # the compiler — no receiver-type narrowing, no method overload
  # disambiguation — but it reliably produces *some* answer for goto /
  # hover when the compiler path returns nothing.
  #
  # Per-file scanner results are cached keyed on (path, mtime) so
  # repeated hovers / goto within the same workspace don't re-read and
  # re-scan every `.cr` file on disk.
  module WorkspaceIndex
    extend self

    private record ScanCache, mtime : Time, tokens : Array(Scanner::Token), symbols : Array(Scanner::SymbolNode)

    @@scan_cache = {} of String => ScanCache
    @@scan_mutex = Mutex.new

    # Directory-listing cache: stop redoing `Dir.each_child` + stat on
    # every single cross-file request. Keyed on the workspace root
    # and invalidated by wall-clock age (30s) since we don't get file
    # watcher notifications without workspace/didChangeWatchedFiles.
    # `MonoInstant` / `monotonic_now` are a compat shim: pre-1.19 this
    # is `Time::Span` / `Time.monotonic`, 1.19+ it's `Time::Instant` /
    # `Time.instant`. See `compat.cr`.
    private record FileListCache, paths : Array(String), expires_at : MonoInstant

    @@file_list_cache = {} of String => FileListCache
    @@file_list_mutex = Mutex.new
    FILE_LIST_TTL = 30.seconds

    # Persistent name index: bare or qualified symbol name ->
    # every DefSite in the workspace that answers to that name.
    # Keys include both the exact symbol name and, for qualified
    # names like `Foo::Bar`, the final segment (`Bar`), so a bare
    # lookup reaches qualified symbols without scanning keys.
    #
    # Maintained incrementally from text_sync notifications and
    # fully warmed in a background fiber once a workspace root is
    # known. Cold queries fall back to the full-scan path so
    # correctness never regresses.
    #
    # `@@file_names` is a path->keys reverse map so eviction on
    # re-index / delete is O(keys-for-this-file) instead of
    # O(total-keys). The memory cost is paid back the first time a
    # watched-file event fires in a large workspace.
    enum WarmState
      Idle
      Warming
      Warmed
    end

    @@name_index = {} of String => Array(DefSite)
    @@file_names = {} of String => Set(String)
    @@name_index_mutex = Mutex.new
    @@warm_state = WarmState::Idle

    def symbols_for(path : String) : Array(Scanner::SymbolNode)?
      scan_entry(path).try(&.symbols)
    end

    def tokens_for(path : String) : Array(Scanner::Token)?
      scan_entry(path).try(&.tokens)
    end

    private def scan_entry(path : String) : ScanCache?
      info = File.info?(path)
      return nil unless info
      mtime = info.modification_time

      @@scan_mutex.synchronize do
        cached = @@scan_cache[path]?
        return cached if cached && cached.mtime == mtime
      end

      source = File.read(path) rescue return nil
      tokens = Scanner.tokenize(source)
      symbols = Scanner.document_symbols(source)
      entry = ScanCache.new(mtime, tokens, symbols)
      @@scan_mutex.synchronize { @@scan_cache[path] = entry }
      entry
    end

    def invalidate(path : String) : Nil
      @@scan_mutex.synchronize { @@scan_cache.delete(path) }
    end

    # Drop cached file lists; the next `each_cr_file` rewalks disk.
    # Called when the client notifies us of create/delete/rename so
    # newly-added files show up in workspace_symbol without waiting
    # the 30s TTL.
    def invalidate_file_listings : Nil
      @@file_list_mutex.synchronize { @@file_list_cache.clear }
    end

    def invalidate_all : Nil
      @@scan_mutex.synchronize { @@scan_cache.clear }
      @@file_list_mutex.synchronize { @@file_list_cache.clear }
      @@name_index_mutex.synchronize do
        @@name_index.clear
        @@file_names.clear
        @@warm_state = WarmState::Idle
      end
    end

    struct DefSite
      getter file : String
      getter line : Int32   # 0-based
      getter column : Int32 # 0-based
      getter kind : Int32   # Protocol::SymbolKind
      getter signature : String?

      def initialize(@file, @line, @column, @kind, @signature = nil)
      end
    end

    struct Reference
      getter file : String
      getter line : Int32
      getter column : Int32
      getter length : Int32

      def initialize(@file, @line, @column, @length)
      end
    end

    # Find every reference to `name` — every identifier-shaped
    # scanner token with that text. String / comment occurrences are
    # filtered out for free by virtue of the scanner not tagging them
    # as identifiers. Definitions are included: callers that want
    # "references excluding the definition" should filter against the
    # DefSite list.
    #
    # For sigiled identifiers pass the full prefix (`@ivar`, `@@cvar`,
    # `$global`) — the scanner emits them as single tokens.
    def find_references(ws : Workspace, name : String, include_buffers : Bool = true) : Array(Reference)
      results = [] of Reference

      open_paths = Set(String).new
      if include_buffers
        ws.documents.each do |doc|
          open_paths << DocumentUri.to_path(doc.uri)
          scan_tokens_for_references(tokens: doc.tokens, file: DocumentUri.to_path(doc.uri), name: name, acc: results)
        end
      end

      if (root = ws.root_path)
        each_cr_file(root) do |path|
          next if open_paths.includes?(path)
          tokens = tokens_for(path)
          next unless tokens
          scan_tokens_for_references(tokens: tokens, file: path, name: name, acc: results)
        end
      end
      results
    end

    # Find tokens matching a qualified name like `Foo::Bar` — the last
    # segment as a Constant token, preceded by `::` + each earlier
    # segment in order. Returns a Reference at the position of the
    # final segment (`Bar`) so editors highlight just that token.
    def find_qualified_references(ws : Workspace, qualified : String) : Array(Reference)
      segments = qualified.split("::")
      return [] of Reference if segments.size < 2
      final = segments.last

      results = [] of Reference
      open_paths = Set(String).new
      ws.documents.each do |doc|
        open_paths << DocumentUri.to_path(doc.uri)
        scan_tokens_for_qualified(doc.tokens, DocumentUri.to_path(doc.uri), segments, final, results)
      end
      if (root = ws.root_path)
        each_cr_file(root) do |path|
          next if open_paths.includes?(path)
          tokens = tokens_for(path)
          next unless tokens
          scan_tokens_for_qualified(tokens, path, segments, final, results)
        end
      end
      results
    end

    private def scan_tokens_for_qualified(tokens : Array(Scanner::Token), file : String, segments : Array(String), final : String, acc : Array(Reference))
      tokens.each_with_index do |tok, i|
        next unless tok.kind == Scanner::Token::Kind::Constant
        next unless tok.text == final
        next unless qualified_prefix_match?(tokens, i, segments)
        acc << Reference.new(file: file, line: tok.line, column: tok.column, length: tok.text.size)
      end
    end

    # Walk backward from `tokens[i]` (the final segment) and confirm
    # each earlier segment is preceded by a `::`. Skips whitespace.
    private def qualified_prefix_match?(tokens : Array(Scanner::Token), i : Int32, segments : Array(String)) : Bool
      j = i - 1
      (segments.size - 2).downto(0) do |seg_idx|
        # expect `::`
        while j >= 0 && (tokens[j].kind.whitespace? || tokens[j].kind.newline?)
          j -= 1
        end
        return false unless j >= 0 && tokens[j].text == "::"
        j -= 1
        while j >= 0 && (tokens[j].kind.whitespace? || tokens[j].kind.newline?)
          j -= 1
        end
        return false unless j >= 0 && tokens[j].kind == Scanner::Token::Kind::Constant
        return false unless tokens[j].text == segments[seg_idx]
        j -= 1
      end
      true
    end

    private def scan_tokens_for_references(tokens : Array(Scanner::Token), file : String, name : String, acc : Array(Reference))
      tokens.each do |tok|
        next unless reference_kind?(tok.kind)
        next unless tok.text == name
        acc << Reference.new(
          file: file,
          line: tok.line,
          column: tok.column,
          length: tok.text.size,
        )
      end
    end

    private def reference_kind?(kind : Scanner::Token::Kind) : Bool
      case kind
      when Scanner::Token::Kind::Identifier,
           Scanner::Token::Kind::Constant,
           Scanner::Token::Kind::IVar,
           Scanner::Token::Kind::CVar,
           Scanner::Token::Kind::Global
        true
      else
        false
      end
    end

    # Find methods (and macros) defined inside a type whose name
    # matches `type_name`. "Inside" means the SymbolNode's direct
    # parent chain reaches a class/struct/module/enum named
    # `type_name` — we don't walk to inherited bases (no type system),
    # so only methods literally defined in the matching class surface.
    #
    # For generic types, pass just the base name: `Array`, not
    # `Array(Int32)`.
    def find_methods_on(ws : Workspace, type_name : String) : Array(DefSite)
      results = [] of DefSite

      open_paths = Set(String).new
      ws.documents.each do |doc|
        open_paths << DocumentUri.to_path(doc.uri)
        doc.symbols.each { |n| walk_for_methods(n, type_name, DocumentUri.to_path(doc.uri), results) }
      end

      if (root = ws.root_path)
        each_cr_file(root) do |path|
          next if open_paths.includes?(path)
          roots = symbols_for(path)
          next unless roots
          roots.each { |n| walk_for_methods(n, type_name, path, results) }
        end
      end
      results
    end

    private def walk_for_methods(node : Scanner::SymbolNode, type_name : String, file : String, acc : Array(DefSite))
      if type_kind?(node.kind) && node.name == type_name
        node.children.each do |child|
          if child.kind == Protocol::SymbolKind::METHOD || child.kind == Protocol::SymbolKind::FUNCTION
            acc << DefSite.new(
              file: file,
              line: child.name_token.line,
              column: child.name_token.column,
              kind: child.kind,
              signature: child.detail,
            )
          end
        end
      end
      node.children.each { |c| walk_for_methods(c, type_name, file, acc) }
    end

    private def type_kind?(kind : Int32) : Bool
      kind == Protocol::SymbolKind::CLASS ||
        kind == Protocol::SymbolKind::STRUCT ||
        kind == Protocol::SymbolKind::MODULE ||
        kind == Protocol::SymbolKind::ENUM
    end

    # Find every top-level-ish definition whose name matches `name`.
    # `doc_text` is consulted first so same-buffer hits come back
    # ordered before cross-file matches; we break ties on file path.
    #
    # When the persistent name index is warm, on-disk lookups are
    # served in O(1) from the index. Before the index finishes its
    # first warm pass we fall back to the full cr_files walk so
    # early requests still return correct results.
    def find_defs(ws : Workspace, name : String, priority_doc : Document? = nil) : Array(DefSite)
      results = [] of DefSite
      qualified_query = name.includes?("::")

      # `priority_doc` bubbles same-buffer hits to the front of
      # the list. But if the buffer is also among `ws.documents`
      # we'd scan it twice and emit one DefSite with file="" plus
      # one with the real path — identical to the user. Track the
      # hit positions from the priority pass and skip re-adding them.
      priority_hits = Set({Int32, Int32}).new
      # SymbolNode.name is always bare ("Spruce"), never qualified
      # ("Mode::Spruce"), so the walk path can't answer a qualified
      # lookup — only the name_index (which we populate with
      # qualified enum-member entries) can.
      if priority_doc && !qualified_query
        before = results.size
        walk(priority_doc.symbols, "", name, results)
        results[before..].each { |d| priority_hits << {d.line, d.column} }
      end

      open_paths = Set(String).new
      ws.documents.each do |d|
        path = DocumentUri.to_path(d.uri)
        open_paths << path
        next if qualified_query
        buf_results = [] of DefSite
        walk(d.symbols, path, name, buf_results)
        buf_results.each do |site|
          next if priority_doc && priority_hits.includes?({site.line, site.column})
          results << site
        end
      end

      root = ws.root_path

      # The name_index may carry entries populated incrementally from
      # reindex_file_from_document even before the warm pass completes
      # — qualified enum-member entries land there, so we have to
      # consult it for qualified queries regardless of warm state.
      consult_index = qualified_query || name_index_ready?
      if consult_index
        @@name_index_mutex.synchronize do
          entries = @@name_index[name]?
          if entries
            entries.each do |site|
              next if open_paths.includes?(site.file) && !qualified_query
              next if priority_doc && priority_hits.includes?({site.line, site.column})
              results << site
            end
          end
        end
      elsif root
        each_cr_file(root) do |path|
          next if open_paths.includes?(path)
          roots = symbols_for(path)
          next unless roots
          walk(roots, path, name, results)
        end
      end

      # Qualified lookups need the parent-qualifying walk that
      # `collect_def_sites` performs — a SymbolNode's own name is
      # bare, so the `walk` path can't match `Rosegold::Bot` against
      # `class Bot` nested inside `module Rosegold`. When the name
      # index hasn't finished its warm pass, scan disk on demand.
      if qualified_query && !name_index_ready? && root && results.empty?
        each_cr_file(root) do |path|
          next if open_paths.includes?(path)
          roots = symbols_for(path)
          next unless roots
          collect_def_sites(roots, path).each do |pair|
            key, site = pair
            results << site if key == name
          end
        end
      end

      results
    end

    def name_index_ready? : Bool
      @@name_index_mutex.synchronize { @@warm_state.warmed? }
    end

    # Idempotent: subsequent calls no-op while warming or warmed.
    def warm_name_index_async(root : String, reporter : ProgressReporter? = nil) : Nil
      @@name_index_mutex.synchronize do
        return unless @@warm_state.idle?
        @@warm_state = WarmState::Warming
      end
      spawn { warm_name_index(root, reporter) }
    end

    # Disk is authoritative here: invalidate first so `symbols_for`
    # re-reads rather than serving the stale mtime cache.
    def reindex_file_from_disk(path : String) : Nil
      invalidate(path)
      roots = symbols_for(path)
      apply_file_index(path, roots ? collect_def_sites(roots, path) : ([] of {String, DefSite}))
    end

    # Buffer is authoritative while the doc is open; no scan-cache
    # invalidation because `doc.symbols` doesn't consult it.
    def reindex_file_from_document(path : String, doc : Document) : Nil
      apply_file_index(path, collect_def_sites(doc.symbols, path))
    end

    private def warm_name_index(root : String, reporter : ProgressReporter?) : Nil
      reporter.try(&.begin("scanning #{File.basename(root)}", percentage: 0))
      paths = cr_files(root)
      total = paths.size
      paths.each_with_index do |path, i|
        roots = symbols_for(path)
        if roots
          apply_file_index(path, collect_def_sites(roots, path))
        end
        if reporter && total > 0 && (i % 25 == 0 || i == total - 1)
          reporter.report("#{i + 1}/#{total} files", percentage: ((i + 1) * 100 // total))
        end
      end
    rescue ex
      Log.debug(exception: ex) { "warm_name_index failed for #{root}" }
    ensure
      reporter.try(&.end_)
      # Only publish Warmed if nothing (invalidate_all, a second
      # warm) has reset us to Idle while we were running — otherwise
      # we'd flip an empty index into "ready" and mask the reset.
      @@name_index_mutex.synchronize do
        @@warm_state = WarmState::Warmed if @@warm_state.warming?
      end
    end

    private def collect_def_sites(nodes : Array(Scanner::SymbolNode), file : String) : Array({String, DefSite})
      acc = [] of {String, DefSite}
      collect_def_sites_walk(nodes, file, acc, "")
      acc
    end

    # Threads a `prefix` through nested type scopes so `module Rosegold;
    # class Bot` ends up indexed as both `"Bot"` (bare) and
    # `"Rosegold::Bot"` (qualified). Without the qualified form a
    # goto-definition on `Rosegold::Bot` produces no hits. Enum members
    # and constants nested inside types ride along for free.
    private def collect_def_sites_walk(nodes : Array(Scanner::SymbolNode), file : String, acc : Array({String, DefSite}), prefix : String)
      nodes.each do |n|
        site = DefSite.new(
          file: file,
          line: n.name_token.line,
          column: n.name_token.column,
          kind: n.kind,
          signature: n.detail,
        )
        acc << {n.name, site}

        # Skip qualifying when the SymbolNode's own name already carries
        # a `::` (e.g. `class Foo::Bar` is stored as `"Foo::Bar"` by
        # the scanner's qualified-name extractor).
        if !prefix.empty? && !n.name.includes?("::")
          acc << {"#{prefix}::#{n.name}", site}
        end

        # Only type-like parents extend the prefix for their children.
        child_prefix = if type_kind?(n.kind)
                         prefix.empty? ? n.name : "#{prefix}::#{n.name}"
                       else
                         prefix
                       end
        collect_def_sites_walk(n.children, file, acc, child_prefix)
      end
    end

    private def type_kind?(kind : Int32) : Bool
      kind == Protocol::SymbolKind::CLASS ||
        kind == Protocol::SymbolKind::STRUCT ||
        kind == Protocol::SymbolKind::MODULE ||
        kind == Protocol::SymbolKind::ENUM
    end

    private def apply_file_index(path : String, pairs : Array({String, DefSite})) : Nil
      @@name_index_mutex.synchronize do
        remove_file_from_index_locked(path)
        keys = Set(String).new
        pairs.each do |pair|
          name, site = pair
          insert_key_locked(name, site, keys)
          # Bare-suffix permutation so a lookup for `Bar` finds
          # `class Foo::Bar`. Mirrors `name_matches?` — a bare
          # query matches a qualified symbol when the final
          # `::`-segment is the query.
          if (last = last_segment(name)) && last != name
            insert_key_locked(last, site, keys)
          end
        end
        @@file_names[path] = keys unless keys.empty?
      end
    end

    private def insert_key_locked(key : String, site : DefSite, keys : Set(String))
      bucket = @@name_index[key] ||= [] of DefSite
      # Dedup: the same site can arrive under multiple spellings
      # (bare + qualified + last-segment permutation) and we don't want
      # callers to see the same location three times.
      return if bucket.any? { |s| s.file == site.file && s.line == site.line && s.column == site.column }
      bucket << site
      keys << key
    end

    private def remove_file_from_index_locked(path : String) : Nil
      keys = @@file_names.delete(path)
      return unless keys
      keys.each do |key|
        bucket = @@name_index[key]?
        next unless bucket
        bucket.reject! { |site| site.file == path }
        @@name_index.delete(key) if bucket.empty?
      end
    end

    private def last_segment(name : String) : String?
      _, sep, last = name.rpartition("::")
      sep.empty? ? nil : last
    end

    private def walk(nodes : Array(Scanner::SymbolNode), file : String, name : String, acc : Array(DefSite))
      nodes.each do |n|
        if name_matches?(n.name, name)
          acc << DefSite.new(
            file: file,
            line: n.name_token.line,
            column: n.name_token.column,
            kind: n.kind,
            signature: n.detail,
          )
        end
        walk(n.children, file, name, acc)
      end
    end

    # Namespace-aware name match. A bare query (`Foo`) matches any
    # symbol whose fully qualified name ends with `::Foo`; a
    # qualified query (`Mod::Foo`) still requires exact equality.
    private def name_matches?(symbol_name : String, query : String) : Bool
      return true if symbol_name == query
      return false if query.includes?("::")
      symbol_name.ends_with?("::#{query}")
    end

    # Public helper so other handlers don't re-roll their own
    # symlink-loop-safe walk. See workspace_symbol.cr / signature_help.cr
    # / type_hierarchy.cr.
    def each_cr_file(root : String, &block : String ->)
      cr_files(root).each { |p| block.call(p) }
    end

    def cr_files(root : String) : Array(String)
      now = CrystalLanguageServer.monotonic_now
      @@file_list_mutex.synchronize do
        cached = @@file_list_cache[root]?
        return cached.paths if cached && cached.expires_at > now
      end

      paths = [] of String
      stack = [root]
      # Shard dep trees routinely contain symlink loops
      # (lib/foo/lib/foo/lib/foo/...). Canonicalize each directory
      # before descending, and skip any realpath we've already seen.
      seen_real = Set(String).new
      until stack.empty?
        dir = stack.pop
        begin
          next unless File.directory?(dir)
          real = (File.realpath(dir) rescue dir)
          next unless seen_real.add?(real)

          Dir.each_child(dir) do |entry|
            next if entry.starts_with?(".")
            path = File.join(dir, entry)
            # Follow symlinks — common shard setups symlink `lib/foo`
            # to a checkout outside the workspace. The seen_real guard
            # above prevents loops via realpath deduplication.
            info = File.info?(path)
            next unless info
            if info.directory?
              # Skip build/output directories but include `lib/` so
              # vendored shard symbols are reachable from goto,
              # references, and rename.
              next if {"node_modules", "bin", "docs"}.includes?(entry)
              stack << path
            elsif entry.ends_with?(".cr") && info.file?
              paths << path
            end
          end
        rescue ex
          Log.debug(exception: ex) { "cr_files: failed to scan #{dir}" }
        end
      end

      @@file_list_mutex.synchronize do
        @@file_list_cache[root] = FileListCache.new(paths, CrystalLanguageServer.monotonic_now + FILE_LIST_TTL)
      end
      paths
    rescue
      [] of String
    end
  end
end
