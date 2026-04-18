module CrystalLanguageServer
  module Handlers
    # `textDocument/selectionRange` — nested ranges for smart
    # expand-selection. Walks the scanner's symbol tree to produce an
    # outermost → innermost chain of ranges covering the cursor.
    module SelectionRange
      extend self

      # LSP SelectionRange is recursively self-typed ({range, parent:
      # SelectionRange?}). NamedTuple can't express that so we use a
      # small class.
      class Item
        include JSON::Serializable
        property range : LspRange
        property parent : Item?

        def initialize(@range, @parent = nil)
        end
      end

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        positions = params["positions"].as_a
        positions.map { |p| compute_range(doc, p["line"].as_i, p["character"].as_i) }
      end

      private def compute_range(doc : Document, line : Int32, character : Int32)
        # Collect ranges inner→outer as (range, priority).
        # Higher priority = tighter (innermost).
        layers = [] of {LspRange, Int32}

        offset = doc.position_to_offset(line, character)
        if word = Scanner.word_at(doc.text, offset)
          start = offset
          while start > 0 && Scanner.identifier_char?(doc.text.byte_at(start - 1).unsafe_chr)
            start -= 1
          end
          stop = start + word.bytesize
          layers << {LspRange.new(doc.offset_to_position(start), doc.offset_to_position(stop)), 1_000_000}
        end

        line_text = doc.line(line)
        layers << {
          LspRange.new(LspPosition.new(line, 0), LspPosition.new(line, line_text.size)),
          500_000,
        }

        doc.symbols.each do |root|
          collect_enclosing(root, doc, line, character, layers, 100_000)
        end

        layers << {
          LspRange.new(LspPosition.new(0, 0), doc.offset_to_position(doc.text.bytesize)),
          0,
        }

        sorted = layers.sort_by! { |(_, p)| -p }.map { |(r, _)| r }
        build_tree(dedupe_and_nest(sorted))
      end

      private def collect_enclosing(node : Scanner::SymbolNode, doc : Document, line : Int32, character : Int32, acc : Array({LspRange, Int32}), depth : Int32)
        full_range = node_range(node, doc)
        return unless contains_pos?(full_range, line, character)

        acc << {full_range, depth}
        name_range = LspRange.new(
          doc.offset_to_position(node.name_token.byte_start),
          doc.offset_to_position(node.name_token.byte_end),
        )
        if contains_pos?(name_range, line, character)
          acc << {name_range, depth + 5_000}
        end

        node.children.each do |child|
          collect_enclosing(child, doc, line, character, acc, depth - 1_000)
        end
      end

      private def node_range(node : Scanner::SymbolNode, doc : Document) : LspRange
        opener_start = doc.offset_to_position(node.opener.byte_start)
        end_offset = (node.end_token.try(&.byte_end)) || node.name_token.byte_end
        LspRange.new(opener_start, doc.offset_to_position(end_offset))
      end

      private def contains_pos?(range : LspRange, line : Int32, character : Int32) : Bool
        s = range.start
        e = range.end_
        return false if line < s.line
        return false if line > e.line
        return false if line == s.line && character < s.character
        return false if line == e.line && character > e.character
        true
      end

      # Drop duplicates and keep only strictly-nested ranges so the
      # SelectionRange chain the client receives is clean (innermost
      # → outermost, each containing the previous).
      private def dedupe_and_nest(ranges : Array(LspRange)) : Array(LspRange)
        out = [] of LspRange
        ranges.each do |r|
          if last = out.last?
            next if same_range?(r, last)
            next unless contains_range?(r, last)
          end
          out << r
        end
        out
      end

      # Build the nested SelectionRange structure: Item(range, parent)
      # where parent is the next broader enclosing range.
      private def build_tree(ranges : Array(LspRange)) : Item?
        return nil if ranges.empty?
        current : Item? = nil
        ranges.reverse_each do |r|
          current = Item.new(r, current)
        end
        current
      end

      private def same_range?(a : LspRange, b : LspRange) : Bool
        a.start.line == b.start.line && a.start.character == b.start.character &&
          a.end_.line == b.end_.line && a.end_.character == b.end_.character
      end

      private def contains_range?(outer : LspRange, inner : LspRange) : Bool
        !pos_after?(outer.start, inner.start) && !pos_after?(inner.end_, outer.end_)
      end

      private def pos_after?(a : LspPosition, b : LspPosition) : Bool
        return true if a.line > b.line
        return false if a.line < b.line
        a.character > b.character
      end
    end
  end
end
