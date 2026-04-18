module CrystalLanguageServer
  module Handlers
    # `textDocument/rangeFormatting` — format a slice of the buffer.
    #
    # The Crystal formatter works on a whole program, not arbitrary
    # slices — feeding it just lines 10-20 of a file would almost
    # always fail because scopes (class / module / def openings) get
    # chopped. So we format the full document, then return edits only
    # for the lines that overlap the requested range. That's the same
    # strategy rust-analyzer uses for slice formatting.
    module RangeFormatting
      extend self

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        r = params["range"]
        start_line = r["start"]["line"].as_i
        end_line = r["end"]["line"].as_i
        end_line = start_line if end_line < start_line

        formatted = ws.compiler.format(doc.text)
        return nil if formatted.nil? || formatted == doc.text

        original_lines = doc.text.lines
        formatted_lines = formatted.lines

        # Clamp to what the formatter produced (it may change line
        # counts for long formatting fixes — in that case fall back to
        # whole-document edit, since line-matching would be wrong).
        if formatted_lines.size != original_lines.size
          full_range = LspRange.new(LspPosition.new(0, 0), doc.offset_to_position(doc.text.bytesize))
          return [{range: full_range, newText: formatted}]
        end

        clamp_end = Math.min(end_line, original_lines.size - 1)
        return [] of Nil if start_line > clamp_end

        edits = [] of NamedTuple(range: LspRange, newText: String)
        (start_line..clamp_end).each do |i|
          original = original_lines[i]
          replacement = formatted_lines[i]
          next if original == replacement
          line_text = doc.line(i)
          edits << {
            range: LspRange.new(
              LspPosition.new(i, 0),
              LspPosition.new(i, line_text.size),
            ),
            newText: replacement.chomp,
          }
        end
        edits
      end
    end
  end
end
