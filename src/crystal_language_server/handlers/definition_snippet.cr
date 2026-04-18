module CrystalLanguageServer
  module Handlers
    # Reads a definition's signature + preceding `#` doc comment from a
    # source file. Used by both Hover (to render the markdown bubble)
    # and Completion (to populate `documentation` / `detail` on items).
    #
    # Pulled out of Hover so the same line-walking logic doesn't drift
    # between handlers.
    module DefinitionSnippet
      extend self

      record Parts, sig_lines : Array(String), doc_lines : Array(String)

      # Read up to 5 signature lines starting at `line` (1-based) and
      # any preceding `#` doc comment block. Returns nil when the file
      # can't be read or `line` is out of range.
      def extract(file : String, line : Int32) : Parts?
        text = File.read(file) rescue return nil
        lines = text.lines
        return nil if line < 1 || line > lines.size

        sig_lines = collect_signature(lines, line)
        doc_lines = collect_doc_comment(lines, line)
        Parts.new(sig_lines: sig_lines, doc_lines: doc_lines)
      end

      # Render Hover's markdown bubble: a fenced sig block, the doc
      # comment (if any), and a footer pointing at the source.
      def render_markdown(file : String, line : Int32) : String?
        parts = extract(file, line)
        return nil unless parts

        String.build do |io|
          io << "```crystal\n"
          parts.sig_lines.each { |l| io << l.lstrip << '\n' }
          io << "```"
          unless parts.doc_lines.empty?
            io << "\n\n"
            io << parts.doc_lines.join("\n")
          end
          io << "\n\n*from #{File.basename(file)}:#{line}*"
        end
      end

      private def collect_signature(lines : Array(String), line : Int32) : Array(String)
        out = [] of String
        i = line - 1
        paren_depth = 0
        while i < lines.size && out.size < 5
          l = lines[i]
          out << l.rstrip
          paren_depth += l.count('(') - l.count(')')
          break if paren_depth <= 0 && !l.rstrip.ends_with?(',')
          i += 1
        end
        out
      end

      private def collect_doc_comment(lines : Array(String), line : Int32) : Array(String)
        out = [] of String
        j = line - 2
        while j >= 0
          stripped = lines[j].lstrip
          break unless stripped.starts_with?("#")
          break if stripped.starts_with?("#!")
          out.unshift(stripped.lchop('#').lstrip.rstrip)
          j -= 1
        end
        out
      end
    end
  end
end
