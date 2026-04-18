module CrystalLanguageServer
  module Handlers
    module FoldingRange
      extend self

      # Emit a folding range for each top-level (and nested) block
      # recognised by the scanner. We don't try to fold non-structural
      # constructs like `if/while` — editor folding for those tends to
      # be noisy, and the scanner doesn't track them.
      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return [] of Nil unless doc

        roots = doc.symbols
        result = [] of NamedTuple(startLine: Int32, endLine: Int32, kind: String)
        collect(roots, result)
        result
      end

      private def collect(nodes, result)
        nodes.each do |n|
          start_line = n.opener.line
          end_line = (n.end_token.try(&.line)) || start_line
          if end_line > start_line
            result << {startLine: start_line, endLine: end_line, kind: "region"}
          end
          collect(n.children, result)
        end
      end
    end
  end
end
