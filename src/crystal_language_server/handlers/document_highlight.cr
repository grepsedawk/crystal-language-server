module CrystalLanguageServer
  module Handlers
    # `textDocument/documentHighlight` — when the cursor is on an
    # identifier, highlight every occurrence in the current buffer. No
    # semantic analysis; scanner-only.
    #
    # We intentionally match across Identifier / Constant / IVar / CVar /
    # Global tokens: a plain word-match would also flag the token inside
    # a string or comment, which we want to avoid. Using the scanner's
    # output gives us string/comment-stripping for free.
    module DocumentHighlight
      extend self

      # LSP DocumentHighlightKind: 1=Text, 2=Read, 3=Write. We don't
      # distinguish read vs. write — tracking assignment requires a
      # small AST walk and isn't worth it for the visual payoff.
      KIND_TEXT = 1

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)
        word = Scanner.word_at(doc.text, byte_offset)
        return nil unless word && !word.empty?

        # `@var` / `@@var` / `$var` read one (or two) preceding sigils
        # — the scanner emits the full sigil-prefixed token text, so we
        # match against that. Extend `word` backwards over any sigils.
        target = Scanner.extend_with_sigils(doc.text, byte_offset, word)

        matches = [] of NamedTuple(range: LspRange, kind: Int32)
        doc.tokens.each do |tok|
          next unless identifier_kind?(tok.kind)
          next unless tok.text == target

          matches << {
            range: LspRange.new(
              doc.offset_to_position(tok.byte_start),
              doc.offset_to_position(tok.byte_end),
            ),
            kind: KIND_TEXT,
          }
        end
        matches
      end

      private def identifier_kind?(kind : Scanner::Token::Kind) : Bool
        case kind
        when Scanner::Token::Kind::Identifier,
             Scanner::Token::Kind::Constant,
             Scanner::Token::Kind::IVar,
             Scanner::Token::Kind::CVar,
             Scanner::Token::Kind::Global
          true
        else
          false
        end
      end
    end
  end
end
