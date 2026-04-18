module CrystalLanguageServer
  # In-memory view of one open text document. Tracks both the raw bytes
  # and a cached array of line-start byte offsets so that converting an
  # LSP (line, character) pair to a byte offset is O(1) after the first
  # line scan.
  #
  # LSP sends `character` in UTF-16 code units. For ASCII and BMP text
  # that matches UTF-8 character counts, but astral characters (emoji,
  # etc.) count as 2 code units in UTF-16 and 1-4 bytes in UTF-8, so the
  # conversion walks the line character-by-character when needed.
  class Document
    getter uri : String
    getter version : Int32
    getter text : String
    getter language_id : String
    @line_offsets : Array(Int32)?
    @tokens : Array(Scanner::Token)?
    @symbols : Array(Scanner::SymbolNode)?
    @declaration_offsets : Set(Int32)?
    @scan_mutex = Mutex.new

    def initialize(@uri, @text, @version = 0, @language_id = "crystal")
    end

    def text=(value : String)
      @text = value
      @line_offsets = nil
      @tokens = nil
      @symbols = nil
      @declaration_offsets = nil
    end

    # Memoized scanner output. Handlers run in fibers; `@scan_mutex`
    # serializes the *first* scan so two concurrent requests don't
    # both tokenize a fresh buffer. Subsequent reads skip the lock.
    def tokens : Array(Scanner::Token)
      if cached = @tokens
        return cached
      end
      @scan_mutex.synchronize { @tokens ||= Scanner.tokenize(@text) }
    end

    def symbols : Array(Scanner::SymbolNode)
      if cached = @symbols
        return cached
      end
      @scan_mutex.synchronize { @symbols ||= Scanner.document_symbols(@text) }
    end

    # Byte offsets of the `name_token` for every declaration (class,
    # module, def, macro, etc.) in this document, cached per version.
    # Used by the semantic-tokens encoder to flip the `declaration`
    # modifier bit on the matching token slot.
    def declaration_offsets : Set(Int32)
      if cached = @declaration_offsets
        return cached
      end
      syms = symbols # computed outside the lock; `symbols` takes its own
      offsets = Set(Int32).new
      collect_declaration_offsets(syms, offsets)
      @scan_mutex.synchronize { @declaration_offsets ||= offsets }
    end

    private def collect_declaration_offsets(nodes : Array(Scanner::SymbolNode), offsets : Set(Int32)) : Nil
      nodes.each do |n|
        offsets << n.name_token.byte_start
        collect_declaration_offsets(n.children, offsets)
      end
    end

    def update(new_text : String, new_version : Int32) : Nil
      self.text = new_text
      @version = new_version
    end

    # Apply an LSP TextDocumentContentChangeEvent. Full or incremental.
    def apply_change(change : JSON::Any) : Nil
      if (r = change["range"]?)
        range_start = position_to_offset(r["start"]["line"].as_i, r["start"]["character"].as_i)
        range_end = position_to_offset(r["end"]["line"].as_i, r["end"]["character"].as_i)
        new_text = change["text"].as_s
        self.text = @text.byte_slice(0, range_start) + new_text + @text.byte_slice(range_end, @text.bytesize - range_end)
      else
        self.text = change["text"].as_s
      end
    end

    def line_count : Int32
      line_offsets.size
    end

    def line(index : Int32) : String
      offsets = line_offsets
      return "" unless (0...offsets.size).includes?(index)
      start = offsets[index]
      stop = offsets[index + 1]? || @text.bytesize
      slice = @text.byte_slice(start, stop - start)
      slice.chomp
    end

    def each_line(& : String, Int32 ->) : Nil
      line_offsets.each_with_index do |_, i|
        yield line(i), i
      end
    end

    # LSP position -> byte offset into `@text`.
    def position_to_offset(line : Int32, character : Int32) : Int32
      offsets = line_offsets
      return @text.bytesize if line >= offsets.size
      line_start = offsets[line]
      line_text = line(line)
      utf16_to_byte_offset(line_text, character) + line_start
    end

    # LSP character offset -> byte offset *within* the given line. Used
    # when we need a 1-based column for the Crystal compiler, which
    # thinks in bytes, not UTF-16 units.
    def column_byte_offset(line : Int32, character : Int32) : Int32
      utf16_to_byte_offset(line(line), character)
    end

    # Count the UTF-16 code units in `s`. Exposed as a class method so
    # handlers (e.g. SemanticTokens) that need to report LSP lengths can
    # share one implementation instead of re-deriving it.
    def self.utf16_length(s : String) : Int32
      n = 0
      s.each_char { |c| n += c.ord > 0xFFFF ? 2 : 1 }
      n
    end

    # byte offset -> LSP position.
    def offset_to_position(offset : Int32) : LspPosition
      offsets = line_offsets
      line = binary_search_line(offsets, offset)
      line_start = offsets[line]
      line_text = @text.byte_slice(line_start, offset - line_start)
      LspPosition.new(line, byte_to_utf16_offset(line_text))
    end

    # --- internal ------------------------------------------------------

    private def line_offsets : Array(Int32)
      @line_offsets ||= begin
        result = [0]
        @text.to_slice.each_with_index do |byte, i|
          if byte == '\n'.ord
            result << (i + 1)
          end
        end
        result
      end
    end

    private def binary_search_line(offsets, offset) : Int32
      low = 0
      high = offsets.size - 1
      while low < high
        mid = (low + high + 1) // 2
        if offsets[mid] <= offset
          low = mid
        else
          high = mid - 1
        end
      end
      low
    end

    # UTF-16 code unit index -> UTF-8 byte offset within `line_text`.
    private def utf16_to_byte_offset(line_text : String, character : Int32) : Int32
      return line_text.bytesize if character <= 0 && line_text.bytesize == 0
      utf16_pos = 0
      byte_pos = 0
      line_text.each_char do |char|
        break if utf16_pos >= character
        cp = char.ord
        utf16_pos += (cp > 0xFFFF ? 2 : 1)
        byte_pos += char.bytesize
      end
      byte_pos
    end

    private def byte_to_utf16_offset(prefix : String) : Int32
      Document.utf16_length(prefix)
    end
  end
end
