module CrystalLanguageServer
  module Handlers
    # `textDocument/prepareRename` — tell the client whether the token
    # at the cursor can be renamed, and if so, what range the rename
    # should replace. Clients use this to (1) show a sensible default
    # in the rename prompt, (2) refuse rename when the cursor is on
    # whitespace / keywords / literals.
    module PrepareRename
      extend self

      # Crystal keywords aren't renamable. Returning nil here lets the
      # editor show a user-friendly "can't rename at this location".
      KEYWORDS = Set{
        "abstract", "alias", "annotation", "as", "begin", "break", "case",
        "class", "def", "do", "else", "elsif", "end", "ensure", "enum",
        "extend", "false", "for", "fun", "if", "in", "include", "lib",
        "macro", "module", "next", "nil", "of", "private", "protected",
        "require", "rescue", "return", "select", "self", "sizeof",
        "struct", "super", "then", "true", "typeof", "uninitialized",
        "union", "unless", "until", "when", "while", "with", "yield",
      }

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)

        word = Scanner.word_at(doc.text, byte_offset)
        return nil unless word && !word.empty?
        return nil if KEYWORDS.includes?(word)

        start = byte_offset
        while start > 0 && Scanner.identifier_char?(doc.text.byte_at(start - 1).unsafe_chr)
          start -= 1
        end
        stop = start + word.bytesize

        # Preserve the @/@@/$ sigil so renaming an ivar actually renames
        # it and doesn't turn `@foo` into a local.
        prefix = ""
        if start > 0
          ch = doc.text.byte_at(start - 1).unsafe_chr
          if ch == '@' || ch == '$'
            prefix = ch.to_s
            start -= 1
            if ch == '@' && start > 0 && doc.text.byte_at(start - 1).unsafe_chr == '@'
              prefix = "@@"
              start -= 1
            end
          end
        end

        {
          range: LspRange.new(
            doc.offset_to_position(start),
            doc.offset_to_position(stop),
          ),
          placeholder: "#{prefix}#{word}",
        }
      end
    end
  end
end
