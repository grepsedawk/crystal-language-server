module CrystalLanguageServer
  module Handlers
    module WorkspaceSymbol
      extend self

      # Rough-and-ready workspace symbol search. We scan every open
      # document plus (if a root is set) every `.cr` file under it,
      # filtering by the query as a case-insensitive substring.
      #
      # Scanning on every keystroke is O(files); for bigger shards we
      # should build an incremental index on startup — good next step.
      def handle(ws : Workspace, params : JSON::Any)
        query = params["query"].as_s
        q = query.downcase

        results = [] of NamedTuple(name: String, kind: Int32, location: NamedTuple(uri: String, range: LspRange), containerName: String?)

        # Open docs first — they're hot and reflect unsaved changes.
        ws.documents.each do |doc|
          collect_from(doc.uri, doc.symbols, q, results)
        end

        if root = ws.root_path
          scanned_uris = Set(String).new
          ws.documents.each { |d| scanned_uris << d.uri }

          WorkspaceIndex.each_cr_file(root) do |path|
            uri = DocumentUri.from_path(path)
            next if scanned_uris.includes?(uri)
            symbols = WorkspaceIndex.symbols_for(path)
            next unless symbols
            collect_from(uri, symbols, q, results)
          end
        end

        results
      end

      private def collect_from(uri, symbols, query, results)
        walk(symbols, nil) do |node, container|
          next unless query.empty? || node.name.downcase.includes?(query)
          start_line = node.name_token.line
          start_col = node.name_token.column
          range = LspRange.new(
            LspPosition.new(start_line, start_col),
            LspPosition.new(start_line, start_col + node.name_token.text.size),
          )
          results << {
            name:          node.name,
            kind:          node.kind,
            location:      {uri: uri, range: range},
            containerName: container,
          }
        end
      end

      private def walk(nodes : Array(Scanner::SymbolNode), container : String?, &block : Scanner::SymbolNode, String? ->)
        nodes.each do |n|
          block.call(n, container)
          walk(n.children, n.name, &block)
        end
      end
    end
  end
end
