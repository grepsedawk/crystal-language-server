module CrystalLanguageServer
  module Handlers
    # Scanner-based call graph. Incoming calls are the workspace
    # references to a def's name, grouped by enclosing def. Outgoing
    # calls are identifier-shaped tokens inside a def's body that
    # match another known def. Approximate — no receiver-type
    # narrowing — but good enough for navigation.
    module CallHierarchy
      extend self

      struct Item
        include JSON::Serializable
        property name : String
        property kind : Int32
        property uri : String
        property range : LspRange
        @[JSON::Field(key: "selectionRange")]
        property selection_range : LspRange
        property detail : String?

        def initialize(@name, @kind, @uri, @range, @selection_range, @detail = nil)
        end
      end

      def prepare(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)
        word = Scanner.word_at(doc.text, byte_offset)
        return nil unless word

        items = [] of Item
        doc.symbols.each do |root|
          walk_find(root, word, doc, uri, items)
        end
        return nil if items.empty?
        items
      end

      def incoming_calls(ws : Workspace, params : JSON::Any)
        item = params["item"]
        name = item["name"].as_s

        item_uri = item["uri"].as_s
        item_line = item.dig?("selectionRange", "start", "line").try(&.as_i) ||
                    item.dig?("range", "start", "line").try(&.as_i) || 0

        refs = WorkspaceIndex.find_references(ws, name)
        refs = drop_local_and_non_call_refs(ws, refs, name, item_uri, item_line)
        # Group references by enclosing def.
        by_caller = {} of String => Array(LspRange)
        refs.each do |ref|
          caller_info = enclosing_def(ref.file, ref.line)
          next unless caller_info
          key = "#{ref.file}|#{caller_info[:name]}|#{caller_info[:line]}"
          arr = by_caller[key] ||= [] of LspRange
          arr << LspRange.new(
            LspPosition.new(ref.line, ref.column),
            LspPosition.new(ref.line, ref.column + ref.length),
          )
        end

        by_caller.map do |key, ranges|
          parts = key.split('|', 3)
          file, caller_name, caller_line_s = parts[0], parts[1], parts[2]
          caller_line = caller_line_s.to_i
          uri = DocumentUri.from_path(file)
          item_range = LspRange.new(
            LspPosition.new(caller_line, 0),
            LspPosition.new(caller_line, caller_name.size),
          )
          caller_item = Item.new(
            name: caller_name,
            kind: Protocol::SymbolKind::METHOD,
            uri: uri,
            range: item_range,
            selection_range: item_range,
          )
          {from: caller_item, fromRanges: ranges}
        end
      end

      def outgoing_calls(ws : Workspace, params : JSON::Any)
        item = params["item"]
        uri = item["uri"].as_s
        doc = ws.documents[uri]?
        range = item["range"]
        start_line = range["start"]["line"].as_i
        end_line = range["end"]["line"].as_i

        # Abstract defs compress to a single line (the signature). They
        # have no body, so no outgoing calls — the alternative is to
        # treat the method's own name as a call and report a
        # self-reference.
        return [] of Nil if start_line == end_line

        # Skip tokens on the def's opener line itself: the method name,
        # parameter names, and return-type identifiers aren't "calls".
        # The body starts on the line after the signature.
        body_start_line = start_line + 1

        tokens = if doc
                   doc.tokens
                 else
                   source = File.read(DocumentUri.to_path(uri)) rescue nil
                   source ? Scanner.tokenize(source) : nil
                 end
        return [] of Nil unless tokens
        called = {} of String => Array(LspRange)
        tokens.each do |tok|
          next unless tok.line >= body_start_line && tok.line <= end_line
          next unless tok.kind == Scanner::Token::Kind::Identifier
          # Heuristic: looks like a call if followed by `(` or by `.`
          # That's also a reference — not perfectly accurate but good
          # enough for a call-hierarchy view.
          arr = called[tok.text] ||= [] of LspRange
          arr << LspRange.new(
            LspPosition.new(tok.line, tok.column),
            LspPosition.new(tok.line, tok.column + tok.text.size),
          )
        end

        # For each called name, try to resolve a def site.
        called.compact_map do |name, ranges|
          sites = WorkspaceIndex.find_defs(ws, name)
          site = sites.find { |s| s.kind == Protocol::SymbolKind::METHOD || s.kind == Protocol::SymbolKind::FUNCTION }
          next nil unless site
          next nil if site.file.empty?
          site_range = LspRange.new(
            LspPosition.new(site.line, site.column),
            LspPosition.new(site.line, site.column + name.size),
          )
          to_item = Item.new(
            name: name,
            kind: site.kind,
            uri: DocumentUri.from_path(site.file),
            range: site_range,
            selection_range: site_range,
            detail: site.signature,
          )
          {to: to_item, fromRanges: ranges}
        end
      end

      private def walk_find(node : Scanner::SymbolNode, name : String, doc : Document, uri : String, acc : Array(Item))
        if node.name == name && callable?(node.kind)
          opener_start = doc.offset_to_position(node.opener.byte_start)
          end_offset = (node.end_token.try(&.byte_end)) || node.name_token.byte_end
          name_range = LspRange.new(
            doc.offset_to_position(node.name_token.byte_start),
            doc.offset_to_position(node.name_token.byte_end),
          )
          acc << Item.new(
            name: node.name,
            kind: node.kind,
            uri: uri,
            range: LspRange.new(opener_start, doc.offset_to_position(end_offset)),
            selection_range: name_range,
            detail: node.detail,
          )
        end
        node.children.each { |c| walk_find(c, name, doc, uri, acc) }
      end

      private def callable?(kind : Int32) : Bool
        kind == Protocol::SymbolKind::METHOD ||
          kind == Protocol::SymbolKind::FUNCTION ||
          kind == Protocol::SymbolKind::CLASS ||
          kind == Protocol::SymbolKind::STRUCT
      end

      private def enclosing_def(file : String, line : Int32) : NamedTuple(name: String, line: Int32)?
        roots = WorkspaceIndex.symbols_for(file)
        return nil unless roots
        match = Scanner.enclosing_callable(roots, line)
        return nil unless match
        {name: match.name, line: match.name_token.line}
      end

      # Mirrors References' method-decl filter: keep declarations,
      # `.`/`::`-prefixed calls, and bare usages only when the
      # enclosing class is in the method's inheritance hierarchy and
      # the enclosing def doesn't locally bind the name.
      private def drop_local_and_non_call_refs(ws : Workspace, refs : Array(WorkspaceIndex::Reference), name : String, item_uri : String, item_line : Int32) : Array(WorkspaceIndex::Reference)
        def_sites = WorkspaceIndex.find_defs(ws, name)
        def_set = def_sites.map { |d| {d.file, d.line, d.column} }.to_set

        open_tokens = {} of String => Array(Scanner::Token)
        open_symbols = {} of String => Array(Scanner::SymbolNode)
        ws.documents.each do |d|
          path = DocumentUri.to_path(d.uri)
          open_tokens[path] = d.tokens
          open_symbols[path] = d.symbols
        end
        hierarchy = item_hierarchy_set(ws, item_uri, item_line, open_symbols)
        token_cache = {} of String => Array(Scanner::Token)
        locality_cache = {} of Tuple(String, Int32) => Bool

        refs.compact_map do |ref|
          next ref if def_set.includes?({ref.file, ref.line, ref.column})
          tokens = token_cache[ref.file]? || (
            src = open_tokens[ref.file]? || WorkspaceIndex.tokens_for(ref.file)
            next nil unless src
            token_cache[ref.file] = src
          )
          idx = tokens.index { |t| t.line == ref.line && t.column == ref.column }
          next nil unless idx
          prev = Scanner.previous_non_whitespace(tokens, idx)
          next ref if prev && (prev.text == "." || prev.text == "::")

          symbols = open_symbols[ref.file]? || WorkspaceIndex.symbols_for(ref.file)
          next nil unless symbols

          if hierarchy
            enclosing = Scanner.enclosing_type(symbols, ref.line)
            next nil unless enclosing && hierarchy.includes?(enclosing.name)
          end

          scope = Scanner.enclosing_callable(symbols, ref.line)
          if scope
            bound = locality_cache[{ref.file, scope.opener.line}] ||= Scanner.locally_bound?(tokens, scope, name)
          else
            bound = locality_cache[{ref.file, -1}] ||= Scanner.bound_anywhere?(tokens, name)
          end
          bound ? nil : ref
        end
      end

      private def item_hierarchy_set(ws : Workspace, item_uri : String, item_line : Int32, open_symbols : Hash(String, Array(Scanner::SymbolNode))) : Set(String)?
        item_path = DocumentUri.to_path(item_uri)
        symbols = open_symbols[item_path]? || WorkspaceIndex.symbols_for(item_path)
        return nil unless symbols
        enclosing = Scanner.enclosing_type(symbols, item_line)
        return nil unless enclosing
        TypeHierarchy.hierarchy_set_for(ws, enclosing.name.split("::").last)
      end
    end
  end
end
