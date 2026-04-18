module CrystalLanguageServer
  module Handlers
    # Scanner-based inheritance graph: parses `class Foo < Bar` from
    # each class's opener line (stored on the SymbolNode's detail).
    # Doesn't resolve through include/extend, typeof, or aliases —
    # enough for everyday class trees, not for full type resolution.
    module TypeHierarchy
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

        sites = WorkspaceIndex.find_defs(ws, word, priority_doc: doc)
        types = sites.select { |s| type_kind?(s.kind) }
        return nil if types.empty?

        types.map { |s| to_item(s, uri) }
      end

      def supertypes(ws : Workspace, params : JSON::Any)
        item = params["item"]
        name = item["name"].as_s
        supers_for(ws, name).map { |site| to_item(site, DocumentUri.from_path(site.file)) }
      end

      def subtypes(ws : Workspace, params : JSON::Any)
        item = params["item"]
        name = item["name"].as_s
        subs_for(ws, name).map { |site| to_item(site, DocumentUri.from_path(site.file)) }
      end

      # --- graph extraction --------------------------------------------

      private def supers_for(ws : Workspace, name : String) : Array(WorkspaceIndex::DefSite)
        sites = WorkspaceIndex.find_defs(ws, name).select { |s| type_kind?(s.kind) }
        parent_names = sites.compact_map { |s| s.signature.try { |d| parent_name(d) } }.uniq
        parent_names.flat_map do |n|
          WorkspaceIndex.find_defs(ws, n).select { |s| type_kind?(s.kind) && !s.file.empty? }
        end
      end

      TYPE_DECL_RE = /(?:class|struct|module)\s+(\S+)/

      # The set of class/struct/module short names forming the
      # transitive-subclass closure of `base_name`. Used by references
      # and call-hierarchy to keep a `BotModule#bot` lookup from pulling
      # in bare `bot` occurrences inside unrelated types.
      def hierarchy_set_for(ws : Workspace, base_name : String) : Set(String)
        set = Set{base_name}
        frontier = [base_name]
        until frontier.empty?
          next_frontier = [] of String
          frontier.each do |type_name|
            subs_for(ws, type_name).each do |sub|
              short = extract_short_name(sub)
              next unless short
              next_frontier << short if set.add?(short)
            end
          end
          frontier = next_frontier
        end
        set
      end

      def extract_short_name(site : WorkspaceIndex::DefSite) : String?
        detail = site.signature
        return nil unless detail
        if m = detail.match(TYPE_DECL_RE)
          m[1].gsub(/\(.*$/, "").split("::").last
        end
      end

      # Public so Implementation can reuse the subtype scan — the
      # same work answers `textDocument/implementation` on a type name.
      def subs_for(ws : Workspace, name : String) : Array(WorkspaceIndex::DefSite)
        # Scan every known type's detail for "< name" or "include name".
        results = [] of WorkspaceIndex::DefSite
        seen = Set(String).new
        collect_all_types(ws).each do |site|
          detail = site.signature
          next unless detail
          next unless supers_contain?(detail, name)
          next unless seen.add?("#{site.file}:#{site.line}")
          results << site
        end
        results
      end

      private def collect_all_types(ws : Workspace) : Array(WorkspaceIndex::DefSite)
        types = [] of WorkspaceIndex::DefSite

        ws.documents.each do |doc|
          path = DocumentUri.to_path(doc.uri)
          doc.symbols.each { |r| gather_types(r, path, types) }
        end

        if root = ws.root_path
          open_paths = Set(String).new
          ws.documents.each { |d| open_paths << DocumentUri.to_path(d.uri) }
          WorkspaceIndex.each_cr_file(root) do |path|
            next if open_paths.includes?(path)
            roots = WorkspaceIndex.symbols_for(path)
            next unless roots
            roots.each { |r| gather_types(r, path, types) }
          end
        end

        types
      end

      private def gather_types(node : Scanner::SymbolNode, file : String, acc : Array(WorkspaceIndex::DefSite))
        if type_kind?(node.kind)
          acc << WorkspaceIndex::DefSite.new(
            file: file,
            line: node.name_token.line,
            column: node.name_token.column,
            kind: node.kind,
            signature: node.detail,
          )
        end
        node.children.each { |c| gather_types(c, file, acc) }
      end

      private def parent_name(detail : String) : String?
        # e.g. "class Foo < Bar" or "class Foo(T) < Base::Child(T)"
        if match = detail.match(/class\s+\S+\s*<\s*([A-Z][A-Za-z0-9_:]*)/)
          match[1]
        elsif match = detail.match(/struct\s+\S+\s*<\s*([A-Z][A-Za-z0-9_:]*)/)
          match[1]
        end
      end

      private def supers_contain?(detail : String, name : String) : Bool
        return true if (p = parent_name(detail)) && p.split("::").last == name
        false
      end

      private def type_kind?(kind : Int32) : Bool
        kind == Protocol::SymbolKind::CLASS ||
          kind == Protocol::SymbolKind::STRUCT ||
          kind == Protocol::SymbolKind::MODULE ||
          kind == Protocol::SymbolKind::ENUM
      end

      private def to_item(site : WorkspaceIndex::DefSite, uri : String) : Item
        pos = LspPosition.new(site.line, site.column)
        width = (site.signature.try(&.size)) || 32
        end_pos = LspPosition.new(site.line, site.column + width)
        range = LspRange.new(pos, end_pos)
        selection = LspRange.new(pos, LspPosition.new(site.line, site.column + 1))
        Item.new(
          name: extract_type_name(site),
          kind: site.kind,
          uri: uri,
          range: range,
          selection_range: selection,
          detail: site.signature,
        )
      end

      private def extract_type_name(site : WorkspaceIndex::DefSite) : String
        if detail = site.signature
          parts = detail.split
          if parts.size >= 2
            return parts[1].gsub(/\(.*\)$/, "")
          end
        end
        ""
      end
    end
  end
end
