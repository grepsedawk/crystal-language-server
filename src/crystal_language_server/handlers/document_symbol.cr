module CrystalLanguageServer
  module Handlers
    module DocumentSymbol
      extend self

      # Produce a hierarchical `DocumentSymbol[]` response by walking
      # the scanner's symbol tree. We prefer the hierarchical form over
      # the flat `SymbolInformation[]` — every modern editor supports it
      # and it renders as a proper outline tree.
      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        roots = doc.symbols
        roots.map { |n| convert(n, doc) }
      end

      # LSP `DocumentSymbol`. We model this as a class rather than a
      # NamedTuple so the type-recursion through `children` is
      # expressible (a NamedTuple can't reference its own enclosing
      # method's return type).
      class Item
        include JSON::Serializable

        property name : String
        property detail : String?
        property kind : Int32
        property range : LspRange
        @[JSON::Field(key: "selectionRange")]
        property selection_range : LspRange
        property children : Array(Item)?

        def initialize(@name, @kind, @range, @selection_range, @detail = nil, @children = nil)
        end
      end

      private def convert(node : Scanner::SymbolNode, doc : Document) : Item
        opener_start = doc.offset_to_position(node.opener.byte_start)
        end_offset = (node.end_token.try(&.byte_end)) || node.name_token.byte_end
        full_range = LspRange.new(opener_start, doc.offset_to_position(end_offset))
        name_range = LspRange.new(
          doc.offset_to_position(node.name_token.byte_start),
          doc.offset_to_position(node.name_token.byte_end),
        )

        children = node.children.empty? ? nil : node.children.map { |c| convert(c, doc) }
        Item.new(
          name: node.name,
          kind: node.kind,
          range: full_range,
          selection_range: name_range,
          detail: node.detail,
          children: children,
        )
      end
    end
  end
end
