module CrystalLanguageServer
  module Handlers
    module Completion
      extend self

      # Crystal keywords and a curated set of built-in pseudo-methods
      # that editors should offer anywhere. Kept in a Set to allow fast
      # de-duplication against file-local identifiers.
      KEYWORDS = %w(
        abstract alias annotation as begin break case class def do else elsif
        end ensure enum extend false for fun if in include lib macro module
        next nil of private protected require rescue return select self
        sizeof struct super then true typeof uninitialized union unless
        until when while with yield
      )

      # Built-in pseudo-methods and macros — the compiler treats them
      # specially and their docs live in the language reference, not in
      # any class. Offering them avoids a blank completion list for new
      # users.
      PSEUDO_METHODS = %w(puts print pp! p p! raise loop spawn sleep gets)

      # Returns a `CompletionItem[]`. Two modes:
      #
      # **Member access** (`foo.`): we ask `crystal tool context` for
      # the receiver's type, then look up methods defined on that type
      # in the workspace via `WorkspaceIndex.find_methods_on`. No type
      # info → no completions (better than offering the kitchen sink).
      #
      # **Free-standing**: keywords + pseudo-methods + workspace
      # symbols + every identifier in the current buffer. The prefix
      # under the cursor filters candidates.
      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return empty_list unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)

        prefix = prefix_at(doc.text, byte_offset)
        trigger_char = params.dig?("context", "triggerCharacter").try(&.as_s?)

        # Member-access completion — short-circuit, don't pollute
        # with unrelated workspace symbols.
        if dot_completion?(doc.text, byte_offset)
          return member_completion(ws, doc, line, character, byte_offset, prefix)
        end

        seen = Set(String).new
        items = [] of Hash(String, JSON::Any)

        unless trigger_char == "." || trigger_char == ":"
          KEYWORDS.each do |k|
            next unless prefix.empty? || k.starts_with?(prefix)
            next unless seen.add?(k)
            items << simple_item(k, Protocol::CompletionItemKind::KEYWORD, "keyword")
          end
          PSEUDO_METHODS.each do |m|
            next unless prefix.empty? || m.starts_with?(prefix)
            next unless seen.add?(m)
            items << simple_item(m, Protocol::CompletionItemKind::FUNCTION, "pseudo-method")
          end
        end

        current_path = DocumentUri.to_path(uri)

        doc.symbols.each do |sym|
          walk_symbol(sym) do |node|
            next if node.name.empty?
            next unless prefix.empty? || node.name.starts_with?(prefix)
            next unless seen.add?(node.name)
            items << local_symbol_item(node, current_path)
          end
        end

        # Cross-file: top-level types/defs from other workspace files.
        # The auto-require additionalTextEdits live here. Keep this
        # gated on a non-empty prefix — without one we'd offer every
        # class in the workspace on a fresh keystroke.
        if !prefix.empty? && trigger_char != "." && trigger_char != ":"
          add_workspace_items(ws, doc, current_path, prefix, seen, items)
        end

        # Pull every identifier-ish token from the buffer — covers
        # locals, ivars, constants the scanner didn't promote to a
        # SymbolNode.
        doc.tokens.each do |tok|
          case tok.kind
          when Scanner::Token::Kind::Identifier,
               Scanner::Token::Kind::Constant,
               Scanner::Token::Kind::IVar,
               Scanner::Token::Kind::CVar
            next if tok.text.empty?
            next unless prefix.empty? || tok.text.starts_with?(prefix)
            next unless seen.add?(tok.text)
            kind = tok.kind == Scanner::Token::Kind::Constant ? Protocol::CompletionItemKind::CONSTANT : Protocol::CompletionItemKind::VARIABLE
            items << simple_item(tok.text, kind, nil)
          end
        end

        {isIncomplete: false, items: items}
      end

      # `completionItem/resolve` — the editor calls this when an item is
      # highlighted. We populate `documentation` from the def's preceding
      # `#` block lazily so the initial completion response stays cheap
      # (no extra File.read per item).
      def resolve(ws : Workspace, params : JSON::Any)
        item = params.as_h.dup
        data = item["data"]?
        return JSON::Any.new(item) unless data

        file = data.dig?("file").try(&.as_s?)
        line = data.dig?("line").try(&.as_i?)
        return JSON::Any.new(item) unless file && line

        if parts = DefinitionSnippet.extract(file, line)
          unless parts.doc_lines.empty?
            item["documentation"] = JSON::Any.new({
              "kind"  => JSON::Any.new("markdown"),
              "value" => JSON::Any.new(parts.doc_lines.join("\n")),
            })
          end

          if !item.has_key?("detail") && !parts.sig_lines.empty?
            item["detail"] = JSON::Any.new(parts.sig_lines.first.lstrip)
          end
        end

        JSON::Any.new(item)
      end

      private def empty_list
        {isIncomplete: false, items: [] of Hash(String, JSON::Any)}
      end

      private def simple_item(label : String, kind : Int32, detail : String?) : Hash(String, JSON::Any)
        h = {
          "label" => JSON::Any.new(label),
          "kind"  => JSON::Any.new(kind.to_i64),
        } of String => JSON::Any
        h["detail"] = JSON::Any.new(detail) if detail
        if (details = label_details_for(kind, detail))
          h["labelDetails"] = JSON::Any.new(details)
        end
        h
      end

      # Short `labelDetails.description` tag per non-callable kind, so
      # the completion popup prefixes class/module/etc. results with a
      # short type indicator. Methods use `split_signature` instead to
      # show `(args) : Return`.
      KIND_DESCRIPTIONS = {
        Protocol::CompletionItemKind::CLASS   => "class",
        Protocol::CompletionItemKind::STRUCT  => "struct",
        Protocol::CompletionItemKind::MODULE  => "module",
        Protocol::CompletionItemKind::ENUM    => "enum",
        Protocol::CompletionItemKind::KEYWORD => "keyword",
      }

      CALLABLE_KINDS = {
        Protocol::CompletionItemKind::METHOD,
        Protocol::CompletionItemKind::FUNCTION,
        Protocol::CompletionItemKind::CONSTRUCTOR,
      }

      # LSP 3.17 `labelDetails`: the small greyed-out bits shown beside
      # the completion label in the popup. `detail` holds the argument
      # list, `description` the return type or a short kind tag.
      private def label_details_for(kind : Int32, detail : String?) : Hash(String, JSON::Any)?
        if CALLABLE_KINDS.includes?(kind)
          return nil unless detail
          args, ret = split_signature(detail)
          h = {} of String => JSON::Any
          h["detail"] = JSON::Any.new(args) if args
          h["description"] = JSON::Any.new(ret) if ret
          h.empty? ? nil : h
        elsif (desc = KIND_DESCRIPTIONS[kind]?)
          {"description" => JSON::Any.new(desc)}
        end
      end

      # Split "def foo(x : Int32, y : String) : Bool" into
      # `{"(x : Int32, y : String)", "Bool"}`. Returns `{nil, nil}` when
      # the shape doesn't match — e.g. a raw signature with no parens.
      private def split_signature(detail : String) : {String?, String?}
        args = nil
        ret = nil
        if (open_idx = detail.index('(')) && (close_idx = matching_paren(detail, open_idx))
          args = detail[open_idx..close_idx]
          tail = detail[(close_idx + 1)..].strip
          if tail.starts_with?(':')
            ret = tail[1..].strip
            ret = nil if ret.empty?
          end
        end
        {args, ret}
      end

      # Track paren depth so return-type annotations that themselves
      # contain parens (Proc(Int32) -> etc.) don't stop the scan early.
      private def matching_paren(s : String, open_idx : Int32) : Int32?
        depth = 0
        i = open_idx
        while i < s.size
          case s[i]
          when '(' then depth += 1
          when ')'
            depth -= 1
            return i if depth == 0
          end
          i += 1
        end
        nil
      end

      private def local_symbol_item(node : Scanner::SymbolNode, current_path : String) : Hash(String, JSON::Any)
        kind = map_symbol_kind(node.kind)
        item = simple_item(node.name, kind, node.detail)
        decorate_callable(item, node, current_path) if callable_kind?(node.kind)
        item
      end

      private def callable_kind?(symbol_kind : Int32) : Bool
        symbol_kind == Protocol::SymbolKind::METHOD || symbol_kind == Protocol::SymbolKind::FUNCTION
      end

      # Add `insertText` with snippet placeholders + a `data` pointer
      # the resolve handler can use to fetch documentation lazily.
      private def decorate_callable(item : Hash(String, JSON::Any), node : Scanner::SymbolNode, file : String) : Nil
        if (detail = node.detail)
          args = required_arg_names(detail)
          unless args.empty?
            placeholders = args.map_with_index { |a, i| "${#{i + 1}:#{a}}" }
            item["insertText"] = JSON::Any.new("#{node.name}(#{placeholders.join(", ")})")
            item["insertTextFormat"] = JSON::Any.new(2_i64) # Snippet
            # Override the workspace `allCommitCharacters` for snippets:
            # typing `.` or `(` while filling placeholders would commit
            # the item and discard the user's in-progress arg.
            item["commitCharacters"] = JSON::Any.new([] of JSON::Any)
          end
        end
        unless file.empty?
          item["data"] = JSON::Any.new({
            "file" => JSON::Any.new(file),
            "line" => JSON::Any.new((node.name_token.line + 1).to_i64),
          })
        end
      end

      # Cross-file class/module/struct/enum/def candidates from other
      # workspace files. Each candidate carries an `additionalTextEdits`
      # entry that inserts the matching `require` at the top of the
      # current buffer if no existing require already covers it.
      private def add_workspace_items(ws : Workspace, doc : Document, current_path : String,
                                      prefix : String, seen : Set(String), items : Array(Hash(String, JSON::Any))) : Nil
        return unless ws.root_path
        existing_requires = required_paths(doc.text, current_path)
        require_insertion = require_insertion_point(doc.text)

        each_workspace_top_level(ws, current_path) do |node, file|
          next if node.name.empty?
          next unless node.name.starts_with?(prefix)
          next unless seen.add?(node.name)

          item = simple_item(node.name, map_symbol_kind(node.kind), node.detail)
          decorate_callable(item, node, file) if callable_kind?(node.kind)
          item["data"] = JSON::Any.new({
            "file" => JSON::Any.new(file),
            "line" => JSON::Any.new((node.name_token.line + 1).to_i64),
          })

          unless existing_requires.includes?(File.expand_path(file))
            if (edit = require_text_edit(file, current_path, require_insertion))
              item["additionalTextEdits"] = JSON::Any.new([edit] of JSON::Any)
            end
          end

          items << item
        end
      end

      private def each_workspace_top_level(ws : Workspace, current_path : String, &block : Scanner::SymbolNode, String ->) : Nil
        return unless (root = ws.root_path)
        open_paths = Set(String).new
        ws.documents.each do |d|
          path = DocumentUri.to_path(d.uri)
          open_paths << path
          next if path == current_path
          d.symbols.each { |n| block.call(n, path) }
        end

        WorkspaceIndex.each_cr_file(root) do |path|
          next if open_paths.includes?(path)
          next if path == current_path
          symbols = WorkspaceIndex.symbols_for(path)
          next unless symbols
          symbols.each { |n| block.call(n, path) }
        end
      end

      # Set of absolute target paths for every `require "..."` in the
      # current buffer that resolves to a file. Bare requires (`require
      # "json"`) — i.e. ones the compiler would resolve via shard
      # search paths — are excluded; we only care about file-local
      # paths the auto-require feature might duplicate.
      private def required_paths(source : String, current_path : String) : Set(String)
        out = Set(String).new
        source.each_line do |line|
          stripped = line.lstrip
          next unless stripped.starts_with?("require")
          rest = stripped[7..]?
          next unless rest
          quote_start = rest.index('"')
          next unless quote_start
          quote_end = rest.index('"', quote_start + 1)
          next unless quote_end
          target = rest[(quote_start + 1)...quote_end]
          next unless target.starts_with?("./") || target.starts_with?("../")
          base = File.dirname(current_path)
          resolved = File.expand_path(target.ends_with?(".cr") ? target : "#{target}.cr", base)
          out << resolved
        end
        out
      end

      # Build a TextEdit hash inserting `require "..."` for `target_path`
      # at the configured insertion line. Returns nil when no relative
      # require can be expressed (different drives / unreachable path).
      private def require_text_edit(target_path : String, current_path : String, insertion_line : Int32) : JSON::Any?
        rel = relative_require_path(target_path, current_path)
        return nil unless rel
        edit = {
          "range" => JSON::Any.new({
            "start" => JSON::Any.new({"line" => JSON::Any.new(insertion_line.to_i64), "character" => JSON::Any.new(0_i64)}),
            "end"   => JSON::Any.new({"line" => JSON::Any.new(insertion_line.to_i64), "character" => JSON::Any.new(0_i64)}),
          }),
          "newText" => JSON::Any.new(%(require "#{rel}"\n)),
        } of String => JSON::Any
        JSON::Any.new(edit)
      end

      # `./foo/bar` form preferred for siblings & descendants; `../`
      # walks for ancestors. Strip the `.cr` suffix — Crystal's require
      # adds it automatically.
      private def relative_require_path(target : String, current : String) : String?
        target_abs = File.expand_path(target)
        current_dir = File.dirname(File.expand_path(current))
        rel = Path[target_abs].relative_to(Path[current_dir]).to_s
        return nil if rel.empty?
        rel = rel[0...-3] if rel.ends_with?(".cr")
        rel = "./#{rel}" unless rel.starts_with?("./") || rel.starts_with?("../")
        rel
      rescue
        nil
      end

      # Insert a new require on the line after the last existing
      # require (so they cluster); if there are none, insert at the
      # top of the file (line 0).
      private def require_insertion_point(source : String) : Int32
        last = -1
        source.each_line.with_index do |line, idx|
          last = idx if line.lstrip.starts_with?("require ")
        end
        last + 1
      end

      private def walk_symbol(node : Scanner::SymbolNode, &block : Scanner::SymbolNode ->)
        block.call(node)
        node.children.each { |c| walk_symbol(c, &block) }
      end

      # Detect whether the cursor is completing after a `.` — i.e. the
      # nearest non-identifier byte before (or at) the cursor is a dot.
      private def dot_completion?(source : String, byte_offset : Int32) : Bool
        i = byte_offset - 1
        while i >= 0 && Scanner.identifier_char?(source.byte_at(i).unsafe_chr)
          i -= 1
        end
        return false if i < 0
        source.byte_at(i).unsafe_chr == '.'
      end

      # Member-access completion: receiver.<prefix|>
      #
      # We find the receiver word immediately before the `.`, ask the
      # compiler for its type in scope at that point, strip any generic
      # parameters, and return the methods defined on that type name
      # in the workspace. Nothing found → empty list (intentional: the
      # editor will then offer identifier matching from its own
      # buffer, which is a reasonable fallback).
      # Per-file cache of the last known receiver → type. Keyed on
      # (uri, receiver_text, stable source hash). Keystrokes typing a
      # prefix after a dot don't change the receiver — reusing the
      # resolution avoids a compiler roundtrip per character.
      private record ReceiverCache, receiver : String, type_name : String, source_hash : UInt64
      @@receiver_cache = {} of String => ReceiverCache
      @@receiver_mutex = Mutex.new

      # Called from TextSync.did_close so closed documents don't leak
      # a cache entry forever.
      def drop_receiver_cache(uri : String) : Nil
        @@receiver_mutex.synchronize { @@receiver_cache.delete(uri) }
      end

      private def member_completion(ws : Workspace, doc : Document, line : Int32, character : Int32, byte_offset : Int32, prefix : String)
        receiver_info = receiver_before_dot(doc.text, byte_offset)
        return empty_list unless receiver_info

        receiver_text = receiver_info[:text]
        receiver_byte = receiver_info[:byte_start]
        receiver_end = receiver_info[:byte_end] # the '.' position

        # Cache key: stable source up to (but not including) the dot,
        # plus the receiver word. While the user types a prefix after
        # the dot, everything up to receiver_end is unchanged, so the
        # cached receiver type is still correct.
        stable_hash = doc.text.byte_slice(0, receiver_end).hash
        cache_key = doc.uri

        cached = @@receiver_mutex.synchronize { @@receiver_cache[cache_key]? }
        receiver_type = if cached && cached.receiver == receiver_text && cached.source_hash == stable_hash
                          cached.type_name
                        else
                          resolved = resolve_receiver_type(ws, doc, receiver_text, receiver_byte, receiver_end, byte_offset)
                          if resolved
                            @@receiver_mutex.synchronize do
                              @@receiver_cache[cache_key] = ReceiverCache.new(receiver_text, resolved, stable_hash)
                            end
                          end
                          resolved
                        end

        # Scanner fallback: if the receiver word is the name of a
        # class/module in the workspace, treat IT as the type without
        # a compiler call. Handles `MyClass.some_class_method`.
        receiver_type ||= scanner_type_for(ws, receiver_text)

        return empty_list unless receiver_type

        type_name = Scanner.strip_type(receiver_type)
        methods = WorkspaceIndex.find_methods_on(ws, type_name)
        return empty_list if methods.empty?

        seen = Set(String).new
        items = [] of Hash(String, JSON::Any)
        methods.each do |m|
          name = method_name_of(m)
          next if name.empty?
          next unless prefix.empty? || name.starts_with?(prefix)
          next unless seen.add?(name)

          item = simple_item(name, Protocol::CompletionItemKind::METHOD, m.signature)
          if (sig = m.signature)
            args = required_arg_names(sig)
            unless args.empty?
              placeholders = args.map_with_index { |a, i| "${#{i + 1}:#{a}}" }
              item["insertText"] = JSON::Any.new("#{name}(#{placeholders.join(", ")})")
              item["insertTextFormat"] = JSON::Any.new(2_i64)
            end
          end
          unless m.file.empty?
            item["data"] = JSON::Any.new({
              "file" => JSON::Any.new(m.file),
              "line" => JSON::Any.new((m.line + 1).to_i64),
            })
          end
          items << item
        end

        {isIncomplete: false, items: items}
      end

      private def resolve_receiver_type(ws, doc, receiver_text, receiver_byte, receiver_end, byte_offset) : String?
        receiver_pos = doc.offset_to_position(receiver_byte)
        cr_line = receiver_pos.line + 1
        cr_col = doc.column_byte_offset(receiver_pos.line, receiver_pos.character) + 1
        path = DocumentUri.to_path(doc.uri)

        # The live source has `g.` or `g.typin` which is a syntax error
        # — the compiler won't type-check it at all. Blank out the dot
        # and any in-progress prefix with spaces so the file parses,
        # while keeping every other byte offset (including the cursor
        # we'll aim at) identical.
        probe_source = source_without_dot_prefix(doc.text, receiver_end, byte_offset)
        types = ws.compiler.context_types(path, probe_source, cr_line, cr_col)
        types.try &.[receiver_text]?
      end

      private def scanner_type_for(ws : Workspace, word : String) : String?
        sites = WorkspaceIndex.find_defs(ws, word)
        sites.each do |s|
          case s.kind
          when Protocol::SymbolKind::CLASS, Protocol::SymbolKind::STRUCT,
               Protocol::SymbolKind::MODULE, Protocol::SymbolKind::ENUM
            return word
          end
        end
        nil
      end

      # The receiver expression immediately before a `.`. Only handles
      # a single identifier / constant for now — `foo.bar.baz` at
      # `baz.|` uses `baz` as receiver, not `foo.bar.baz`, which is the
      # common and cheap case. Chain-typing would need real parsing.
      private def receiver_before_dot(source : String, byte_offset : Int32)
        i = byte_offset - 1
        # skip the prefix we're typing
        while i >= 0 && Scanner.identifier_char?(source.byte_at(i).unsafe_chr)
          i -= 1
        end
        return nil if i < 0
        return nil unless source.byte_at(i).unsafe_chr == '.'
        dot_byte = i
        # skip the dot
        i -= 1
        # strip whitespace (rare but Crystal allows it)
        while i >= 0 && source.byte_at(i).unsafe_chr.in?(' ', '\t')
          i -= 1
        end
        # read the receiver word backwards
        stop = i + 1
        while i >= 0 && Scanner.identifier_char?(source.byte_at(i).unsafe_chr)
          i -= 1
        end
        start = i + 1
        return nil if start == stop
        {byte_start: start, byte_end: dot_byte, text: source.byte_slice(start, stop - start)}
      end

      # Replace bytes [dot_pos, cursor_pos) with spaces so the compiler
      # sees a parseable file. Preserves all other content byte-for-byte
      # so the compiler's line/column for the receiver stays identical.
      private def source_without_dot_prefix(source : String, dot_pos : Int32, cursor_pos : Int32) : String
        return source if dot_pos < 0 || cursor_pos <= dot_pos
        String.build(source.bytesize) do |io|
          io.write(source.to_slice[0, dot_pos])
          (cursor_pos - dot_pos).times { io << ' ' }
          io.write(source.to_slice[cursor_pos, source.bytesize - cursor_pos])
        end
      end

      private def method_name_of(site : WorkspaceIndex::DefSite) : String
        # The SymbolNode's `name_token` text is the method name. We
        # embed that in the signature as `def <name>(`, so re-extract
        # rather than storing the raw name twice.
        sig = site.signature
        return "" unless sig
        # `def name(…)` or `def name` — extract after the first space.
        # Macros look the same shape (`macro name(...)`) — works fine.
        first_space = sig.index(' ')
        return "" unless first_space
        rest = sig[(first_space + 1)..]
        paren = rest.index('(')
        paren ? rest[0...paren] : rest.split.first
      end

      private def prefix_at(source : String, byte_offset : Int32) : String
        stop = byte_offset
        start = stop
        while start > 0
          ch = source.byte_at(start - 1).unsafe_chr
          break unless Scanner.identifier_char?(ch) || ch == '@'
          start -= 1
        end
        source.byte_slice(start, stop - start)
      end

      # Pull the names of required positional args out of a captured
      # signature like `def foo(a, b = 1, *args, &block)`. Returns
      # `["a"]`. Splats, blocks, and any arg with a default are
      # skipped — they're optional and shouldn't be snippet
      # placeholders the user has to step through.
      def required_arg_names(sig : String) : Array(String)
        open = sig.index('(')
        close = sig.rindex(')')
        return [] of String unless open && close && close > open

        inner = sig[(open + 1)...close]
        return [] of String if inner.empty?

        out = [] of String
        split_top_level(inner).each do |piece|
          piece = piece.strip
          next if piece.empty?
          next if piece.starts_with?('*') || piece.starts_with?('&')
          next if piece.includes?('=')
          name = piece.split(':').first.strip
          # External name when the def uses `def foo(external internal)`.
          # Crystal's signature shape uses `(external internal : Type)`;
          # the placeholder we want is the external name (what callers
          # write at the call site).
          space = name.index(' ')
          name = name[0...space] if space
          out << name unless name.empty?
        end
        out
      end

      private def split_top_level(str : String) : Array(String)
        result = [] of String
        depth = 0
        buf = String::Builder.new
        str.each_char do |c|
          case c
          when '(', '[', '{' then depth += 1; buf << c
          when ')', ']', '}' then depth -= 1; buf << c
          when ','
            if depth == 0
              result << buf.to_s
              buf = String::Builder.new
            else
              buf << c
            end
          else buf << c
          end
        end
        tail = buf.to_s
        result << tail unless tail.empty?
        result
      end

      private def map_symbol_kind(sk : Int32) : Int32
        case sk
        when Protocol::SymbolKind::CLASS     then Protocol::CompletionItemKind::CLASS
        when Protocol::SymbolKind::STRUCT    then Protocol::CompletionItemKind::STRUCT
        when Protocol::SymbolKind::MODULE    then Protocol::CompletionItemKind::MODULE
        when Protocol::SymbolKind::ENUM      then Protocol::CompletionItemKind::ENUM
        when Protocol::SymbolKind::METHOD    then Protocol::CompletionItemKind::METHOD
        when Protocol::SymbolKind::FUNCTION  then Protocol::CompletionItemKind::FUNCTION
        when Protocol::SymbolKind::NAMESPACE then Protocol::CompletionItemKind::MODULE
        else                                      Protocol::CompletionItemKind::TEXT
        end
      end
    end
  end
end
