module CrystalLanguageServer
  module Handlers
    # `textDocument/inlayHint` — ghost annotations showing the inferred
    # type next to a local variable declaration.
    #
    # Strategy:
    #
    #   1. Walk the scanner's symbol tree, collecting each `def` node.
    #   2. For each def, invoke `crystal tool context` at a point
    #      *inside its body* — this gives us a `name -> type` map
    #      covering arguments and all locals visible within the def.
    #   3. Scan the def body for `name =` assignments; emit an inlay
    #      hint right after the variable's name with `: TypeName`.
    #
    # Methods that the compiler never instantiated (uncalled defs)
    # produce no context and therefore no hints — this is a known
    # limitation of the current `crystal tool` surface rather than
    # something we can work around without a full compiler session.
    #
    # Cached by (uri, version) so scrolling doesn't re-shell-out on
    # every request; invalidated by any document update.
    module InlayHints
      extend self

      LOCAL_ASSIGN = /^(\s*)([a-z_][a-zA-Z0-9_]*)(\s*)=[^=]/

      # Types that add no information — skip them so the buffer isn't
      # littered with `: NoReturn` annotations on unreachable branches.
      UNINTERESTING = Set{"NoReturn", ""}

      @@cache = {} of String => {version: Int32, hints: Array(Hint)}
      @@cache_mutex = Mutex.new

      # Called from TextSync.did_close so closed documents don't retain
      # their (potentially large) hint arrays.
      def drop(uri : String) : Nil
        @@cache_mutex.synchronize { @@cache.delete(uri) }
      end

      struct Hint
        include JSON::Serializable
        getter position : LspPosition
        getter label : String
        getter kind : Int32 # 1 = Type, 2 = Parameter
        getter paddingLeft : Bool
        getter paddingRight : Bool

        def initialize(@position, @label, @kind = 1, @paddingLeft = false, @paddingRight = false)
        end
      end

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return [] of Hint unless doc

        range = params["range"]?
        requested = range ? parse_range(range) : nil

        hints = cached_hints(ws, doc)
        return hints if requested.nil?
        hints.select { |h| within_range?(h.position, requested) }
      end

      # --- cache -------------------------------------------------------

      private def cached_hints(ws : Workspace, doc : Document) : Array(Hint)
        @@cache_mutex.synchronize do
          cached = @@cache[doc.uri]?
          if cached && cached[:version] == doc.version
            return cached[:hints]
          end
        end

        computed = compute_hints(ws, doc)

        @@cache_mutex.synchronize do
          @@cache[doc.uri] = {version: doc.version, hints: computed}
        end
        computed
      end

      # --- compute -----------------------------------------------------

      private def compute_hints(ws : Workspace, doc : Document) : Array(Hint)
        hints = [] of Hint
        path = DocumentUri.to_path(doc.uri)

        # Collect every cursor we'd want context for: the top of the
        # file (for script-style locals) plus the first line inside
        # each method body. One batch call resolves the whole set,
        # which in embedded mode is one compile + N visitor passes
        # instead of N full compiles.
        def_nodes = [] of Scanner::SymbolNode
        doc.symbols.each { |r| collect_defs(r, def_nodes) }

        cursors = [{1, 1}]
        def_ranges = def_nodes.compact_map do |node|
          r = def_body_range(doc, node)
          next nil unless r
          cursor = {r[:start_line] + 1, 1}
          cursors << cursor
          {cursor: cursor, range: r}
        end

        batch = ws.compiler.contexts_batch(path, doc.text, cursors.uniq)

        if top_types = batch[{1, 1}]?
          emit_hints(doc, 0, doc.line_count - 1, top_types, hints)
        end

        def_ranges.each do |entry|
          types = batch[entry[:cursor]]?
          next unless types
          emit_hints(doc, entry[:range][:start_line], entry[:range][:end_line], types, hints)
        end

        dedupe(hints)
      end

      private def dedupe(hints : Array(Hint)) : Array(Hint)
        seen = Set({Int32, Int32}).new
        hints.select do |h|
          key = {h.position.line, h.position.character}
          seen.add?(key)
        end
      end

      private def collect_defs(node : Scanner::SymbolNode, acc : Array(Scanner::SymbolNode))
        if node.kind == Protocol::SymbolKind::METHOD || node.kind == Protocol::SymbolKind::FUNCTION
          acc << node
        end
        node.children.each { |c| collect_defs(c, acc) }
      end

      private def def_body_range(doc : Document, node : Scanner::SymbolNode)
        start_line = node.opener.line + 1 # one line past the `def` line
        end_line = (node.end_token.try(&.line)) || (start_line + 1)
        return nil if start_line > end_line || start_line >= doc.line_count
        {start_line: start_line, end_line: end_line}
      end

      # Scan the given line range for `name = ...` patterns and emit
      # hints whose type we have. Skip when the line already contains
      # `name : Type =` (explicit annotation) or the var name isn't in
      # `types`.
      private def emit_hints(doc : Document, from : Int32, to : Int32, types : Hash(String, String), hints : Array(Hint))
        seen_per_line = Set(String).new
        (from..Math.min(to, doc.line_count - 1)).each do |line_idx|
          line_text = doc.line(line_idx)
          next if line_text.empty?
          match = LOCAL_ASSIGN.match(line_text)
          next unless match
          indent = match[1]
          var_name = match[2]
          spacing = match[3]

          next if UNINTERESTING.includes?(types[var_name]?)
          type_str = types[var_name]?
          next unless type_str
          next if seen_per_line.includes?(var_name)
          seen_per_line << var_name

          # Skip if there's already a `:` between the variable and `=`
          # — user wrote `x : Int32 = 1` and wants no decoration.
          remainder = line_text[(indent.size + var_name.size)..]
          next if remainder.lstrip.starts_with?(':')

          column = indent.size + var_name.size
          hints << Hint.new(
            position: LspPosition.new(line_idx, column),
            label: " : #{type_str}",
            kind: 1,
            paddingLeft: false,
            paddingRight: true,
          )
        end
      end

      # --- helpers -----------------------------------------------------

      private def parse_range(json : JSON::Any)
        s = json["start"]
        e = json["end"]
        {
          start_line: s["line"].as_i, start_char: s["character"].as_i,
          end_line: e["line"].as_i, end_char: e["character"].as_i,
        }
      end

      private def within_range?(pos : LspPosition, r) : Bool
        return false if pos.line < r[:start_line] || pos.line > r[:end_line]
        if pos.line == r[:start_line] && pos.character < r[:start_char]
          return false
        end
        if pos.line == r[:end_line] && pos.character > r[:end_char]
          return false
        end
        true
      end
    end
  end
end
