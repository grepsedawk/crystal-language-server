module CrystalLanguageServer
  # A 0-based (line, character) pair exchanged with the client.
  #
  # Per the LSP spec a `character` offset is measured in UTF-16 code units,
  # which differs from Crystal's byte-indexed strings. Conversion happens
  # on the Document boundary (see document.cr); this struct is protocol-
  # level only.
  struct LspPosition
    include JSON::Serializable

    getter line : Int32
    getter character : Int32

    def initialize(@line, @character)
    end

    def <=>(other : LspPosition)
      cmp = line <=> other.line
      cmp.zero? ? character <=> other.character : cmp
    end
  end

  struct LspRange
    include JSON::Serializable

    getter start : LspPosition
    @[JSON::Field(key: "end")]
    getter end_ : LspPosition

    def initialize(@start, @end_)
    end

    def self.single(position : LspPosition)
      new(position, position)
    end
  end

  struct LspLocation
    include JSON::Serializable

    getter uri : String
    getter range : LspRange

    def initialize(@uri, @range)
    end
  end
end
