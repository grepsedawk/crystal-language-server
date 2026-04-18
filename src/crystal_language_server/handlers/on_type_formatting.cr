module CrystalLanguageServer
  module Handlers
    # `textDocument/onTypeFormatting` — auto-indent after a newline.
    # Triggered by `\n`. Indents the new line based on the previous
    # non-blank line's leading whitespace, plus two spaces when that
    # line opens a block (`def`, `class`, `module`, `do`, `begin`,
    # `if`/`unless`/`case`/`while`/`until` without a trailing
    # expression, etc.) — matching Crystal's conventional 2-space
    # indent.
    #
    # We don't try to be clever about closing `end` or `else` — the
    # formatter on save will clean that up. This is just enough to
    # avoid the "stuck at column 0" frustration between saves.
    module OnTypeFormatting
      extend self

      INDENT = "  "

      # Any line whose last non-comment token is one of these opens a
      # block that deserves an extra indent.
      BLOCK_OPENERS = Set{
        "def", "class", "module", "struct", "enum", "lib", "macro",
        "annotation", "do", "begin", "case", "if", "unless", "while",
        "until", "ensure", "rescue", "else", "elsif", "when", "in",
        "then", "fun", "->",
      }

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        ch = params["ch"].as_s
        return nil unless ch == "\n"

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i

        return nil if line <= 0
        # Walk upward to the last non-blank line.
        prev_line = line - 1
        while prev_line >= 0
          text = doc.line(prev_line)
          break unless text.strip.empty?
          prev_line -= 1
        end
        return nil if prev_line < 0

        prev_text = doc.line(prev_line)
        indent = leading_whitespace(prev_text)
        indent = "#{indent}#{INDENT}" if opens_block?(prev_text)

        current_line_text = doc.line(line)
        return nil if current_line_text.starts_with?(indent) && indent.size == character

        [{
          range: LspRange.new(
            LspPosition.new(line, 0),
            LspPosition.new(line, character),
          ),
          newText: indent,
        }]
      end

      private def leading_whitespace(text : String) : String
        i = 0
        while i < text.bytesize
          ch = text.byte_at(i).unsafe_chr
          break unless ch == ' ' || ch == '\t'
          i += 1
        end
        text.byte_slice(0, i)
      end

      private def opens_block?(line : String) : Bool
        stripped = strip_trailing_comment(line).rstrip
        return false if stripped.empty?
        # Literal `do` / `do |…|` — the most common block form.
        return true if stripped.ends_with?(" do") || stripped.ends_with?("\tdo") || stripped == "do"
        return true if stripped.ends_with?("|") && stripped.includes?(" do ")

        # Grab the first keyword on the line. This is crude — we're
        # not a real parser — but it matches 95% of block-opening
        # intent without false positives on assignments like `x = if`.
        first = stripped.lstrip.split(/[\s(]/, 2).first
        return true if BLOCK_OPENERS.includes?(first)

        # `->(…){ … }` fits on one line and doesn't open a block.
        # Nothing else opens a block on Crystal.
        false
      end

      private def strip_trailing_comment(line : String) : String
        # Crystal strings can contain `#`, so a raw `index('#')` would
        # miscount. Fast heuristic: find the last run of `#` preceded
        # by whitespace; if none, keep the line.
        i = line.size - 1
        while i >= 0
          if line[i] == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t')
            return line[0...i].rstrip
          end
          i -= 1
        end
        line
      end
    end
  end
end
