module CrystalLanguageServer
  module Handlers
    # LSP semantic tokens, delivered as a flat `Int[]` encoding the
    # spec's "relative deltas" format: for each token,
    #   [deltaLine, deltaStartChar, length, tokenType, tokenModifierBitmask]
    # where deltaLine/deltaStartChar are relative to the previous token.
    module SemanticTokens
      extend self

      TOKEN_TYPES = %w(
        namespace type class enum interface struct typeParameter
        parameter variable property enumMember event function method
        macro keyword modifier comment string number regexp operator
      )

      TOKEN_MODIFIERS = %w(
        declaration definition readonly static deprecated abstract
        async modification documentation defaultLibrary
      )

      TYPE_IDX     = TOKEN_TYPES.each_with_index.to_h
      MODIFIER_IDX = TOKEN_MODIFIERS.each_with_index.to_h

      # Modifier bitmasks precomputed at load time so the per-token hot
      # path only does ORs / Set probes — never a hash lookup per token.
      DECL_BITS    = (1 << MODIFIER_IDX["declaration"]) | (1 << MODIFIER_IDX["definition"])
      READONLY_BIT = 1 << MODIFIER_IDX["readonly"]
      STDLIB_BIT   = 1 << MODIFIER_IDX["defaultLibrary"]

      # Curated subset of Crystal stdlib types worth tagging with the
      # `defaultLibrary` modifier so editors can color them distinctly.
      # Not exhaustive — the goal is "common names the user reaches for
      # daily" rather than an encyclopedia.
      STDLIB_TYPES = Set(String).new(%w(
        Array Bool Char Class Deque Dir Enumerable Exception File Float
        Float32 Float64 Hash IO Indexable Int Int8 Int16 Int32 Int64 Int128
        Iterable Iterator JSON Log NamedTuple Nil Number Object Path Pointer
        Proc Range Reference Regex Set Slice Socket String StringPool Struct
        Symbol Time Tuple UInt8 UInt16 UInt32 UInt64 UInt128 URI Value YAML
      ))

      # Last-sent full payload per uri, keyed with the `doc.version` it
      # was produced for so a delta request on the same version can skip
      # the re-encode. Bounded to open docs; dropped from
      # TextSync.did_close.
      @@last_sent = {} of String => {result_id: String, version: Int32, data: Array(Int32)}
      @@last_sent_mutex = Mutex.new
      @@next_result_id = Atomic(Int64).new(0_i64)

      def drop(uri : String) : Nil
        @@last_sent_mutex.synchronize { @@last_sent.delete(uri) }
      end

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return {resultId: next_result_id, data: [] of Int32} unless doc

        data = encoded_for(uri, doc)
        record_full(uri, doc.version, data)
      end

      # `textDocument/semanticTokens/range` — same encoding, but only
      # tokens whose position falls inside the requested range. Editors
      # use this when scrolling large files so they don't re-encode
      # thousands of off-screen tokens.
      def handle_range(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return {data: [] of Int32} unless doc

        r = params["range"]
        start_line = r["start"]["line"].as_i
        end_line = r["end"]["line"].as_i

        tokens = doc.tokens.select do |tok|
          tok.line >= start_line && tok.line <= end_line
        end
        data = encode(doc, tokens)
        {data: data}
      end

      # `textDocument/semanticTokens/full/delta`. Editors like VS Code
      # call this instead of `/full` when they already have a prior
      # result; we return either a diff (a single `SemanticTokensEdit`
      # covering the changed middle) or, if the previous payload is
      # unknown to us, fall back to a full response.
      def handle_delta(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        prev_id = params["previousResultId"]?.try(&.as_s?)
        doc = ws.documents[uri]?
        return {resultId: next_result_id, data: [] of Int32} unless doc

        new_data = encoded_for(uri, doc)
        prev = @@last_sent_mutex.synchronize { @@last_sent[uri]? }

        if prev && prev_id && prev[:result_id] == prev_id
          edits = diff_edits(prev[:data], new_data)
          return {resultId: record_full(uri, doc.version, new_data)[:resultId], edits: edits}
        end

        record_full(uri, doc.version, new_data)
      end

      # Reuse the last-encoded payload when the doc hasn't changed —
      # a client that rapidly re-requests tokens on the same version
      # (VS Code sometimes does this when it invalidates its cache)
      # skips the quadratic re-encode.
      private def encoded_for(uri : String, doc : Document) : Array(Int32)
        cached = @@last_sent_mutex.synchronize { @@last_sent[uri]? }
        return cached[:data] if cached && cached[:version] == doc.version
        encode(doc, doc.tokens)
      end

      # Minimal single-edit diff: skip the common prefix and common
      # suffix, emit one edit covering the changed middle. This keeps
      # the protocol happy while avoiding a full LCS implementation —
      # the common case (a single-line edit adds/removes a handful of
      # tokens) compresses to an edit spanning ~5-10 ints.
      private def diff_edits(old_data : Array(Int32), new_data : Array(Int32))
        prefix = 0
        max_prefix = Math.min(old_data.size, new_data.size)
        while prefix < max_prefix && old_data[prefix] == new_data[prefix]
          prefix += 1
        end

        suffix = 0
        max_suffix = Math.min(old_data.size, new_data.size) - prefix
        while suffix < max_suffix &&
              old_data[old_data.size - 1 - suffix] == new_data[new_data.size - 1 - suffix]
          suffix += 1
        end

        delete_count = old_data.size - prefix - suffix
        new_slice = new_data[prefix, new_data.size - prefix - suffix]

        return [] of NamedTuple(start: Int32, deleteCount: Int32, data: Array(Int32)) if delete_count == 0 && new_slice.empty?

        [{start: prefix, deleteCount: delete_count, data: new_slice}]
      end

      private def record_full(uri : String, version : Int32, data : Array(Int32))
        result_id = next_result_id
        @@last_sent_mutex.synchronize do
          @@last_sent[uri] = {result_id: result_id, version: version, data: data}
        end
        {resultId: result_id, data: data}
      end

      private def next_result_id : String
        @@next_result_id.add(1).to_s
      end

      private def encode(doc : Document, tokens : Array(Scanner::Token)) : Array(Int32)
        data = [] of Int32
        last_line = 0
        last_col = 0
        declarations = doc.declaration_offsets

        tokens.each do |tok|
          type = token_type(tok)
          next unless type

          pos = doc.offset_to_position(tok.byte_start)
          length = tok_utf16_length(doc, tok)
          delta_line = pos.line - last_line
          delta_col = delta_line == 0 ? pos.character - last_col : pos.character
          data << delta_line << delta_col << length << TYPE_IDX[type] << modifier_bits(tok, declarations)

          last_line = pos.line
          last_col = pos.character
        end
        data
      end

      private def modifier_bits(tok : Scanner::Token, declarations : Set(Int32)) : Int32
        bits = 0
        bits |= DECL_BITS if declarations.includes?(tok.byte_start)
        if tok.kind == Scanner::Token::Kind::Constant
          bits |= READONLY_BIT
          bits |= STDLIB_BIT if STDLIB_TYPES.includes?(tok.text)
        end
        bits
      end

      private def tok_utf16_length(doc, tok) : Int32
        start = doc.offset_to_position(tok.byte_start)
        stop = doc.offset_to_position(tok.byte_end)
        # For multi-line tokens (strings, heredocs, comments) the LSP
        # spec doesn't require re-splitting — clients handle length
        # crossing newlines — but VSCode in particular is happier with
        # same-line lengths, so we clamp to the first line.
        return stop.character - start.character if stop.line == start.line
        # Fallback: compute up to end of first line.
        line_text = doc.line(start.line)
        Document.utf16_length(line_text) - start.character
      end

      private def token_type(tok : Scanner::Token) : String?
        case tok.kind
        when Scanner::Token::Kind::Keyword then "keyword"
        when Scanner::Token::Kind::Comment then "comment"
        when Scanner::Token::Kind::String,
             Scanner::Token::Kind::Char then "string"
        when Scanner::Token::Kind::Number   then "number"
        when Scanner::Token::Kind::Regex    then "regexp"
        when Scanner::Token::Kind::Symbol   then "enumMember"
        when Scanner::Token::Kind::Constant then "type"
        when Scanner::Token::Kind::IVar,
             Scanner::Token::Kind::CVar then "property"
        when Scanner::Token::Kind::Global   then "variable"
        when Scanner::Token::Kind::Operator then "operator"
        else                                     nil
        end
      end
    end
  end
end
