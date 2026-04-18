module CrystalLanguageServer
  # Lightweight Crystal tokenizer. Not a substitute for the real compiler
  # parser — it intentionally knows about the smallest subset of Crystal
  # we need for:
  #
  #   * document symbols / outline (class/module/struct/enum/lib/def/...)
  #   * semantic token highlighting (keywords, strings, numbers, comments)
  #   * identifying the word under a cursor for goto/hover fallbacks
  #
  # Everything semantic (types, method resolution, etc.) goes through the
  # real compiler via Compiler::Provider. The scanner is deliberately forgiving:
  # it skips what it doesn't understand rather than raising.
  module Scanner
    extend self

    KEYWORDS = Set(String).new(%w(
      abstract alias annotation as asm begin break case class def do else elsif
      end ensure enum extend false for fun if in include instance_sizeof is_a?
      lib macro module next nil nil? of offsetof out pointerof private protected
      require rescue responds_to? return select self sizeof struct super then
      true type typeof uninitialized union unless until verbatim when while with
      yield
    ))

    # A single scanned token. `byte_start`/`byte_end` are byte offsets
    # into the source; `line`/`column` are 0-based positions mirroring
    # LSP coordinates for the *byte* column (callers convert to UTF-16
    # on the Document boundary when needed).
    struct Token
      enum Kind
        Keyword
        Identifier
        Constant # Uppercase-leading: class names, constants
        IVar     # @ivar
        CVar     # @@cvar
        Global   # $global
        Symbol   # :foo
        String
        Char
        Number
        Regex
        Comment
        Punctuation
        Operator
        Newline
        Whitespace
        Unknown
      end

      getter kind : Kind
      getter text : String
      getter byte_start : Int32
      getter byte_end : Int32
      getter line : Int32
      getter column : Int32

      def initialize(@kind, @text, @byte_start, @byte_end, @line, @column)
      end
    end

    # Tokenize `source`. Comments and strings are returned as single
    # tokens — we do not descend into string interpolation. Good enough
    # for highlighting and symbol extraction.
    def tokenize(source : String) : Array(Token)
      tokens = [] of Token
      reader = Reader.new(source)
      while tok = reader.next_token
        tokens << tok
      end
      tokens
    end

    # Extract document symbols (flat list, with parent indices). A symbol
    # like `class Foo` opens a scope; the next unmatched `end` closes it.
    # We track nesting via keyword counters, not a full parser, which is
    # why patterns like `rescue` or `ensure` count as neutral — they
    # appear inside the enclosing block and do not change depth.
    def document_symbols(source : String) : Array(SymbolNode)
      tokens = tokenize(source)
      roots = [] of SymbolNode
      stack = [] of SymbolNode

      i = 0
      abstract_modifier = false
      # Crystal's `end` closes both our real scope nodes (class/def/…)
      # and constructs we don't model as SymbolNodes — `if`/`while`/
      # `case`/`begin`/`do`. Every `end` from one of those pseudo-
      # scopes must NOT pop the real stack, or the first nested `if`
      # inside a def will close the enclosing class prematurely and
      # orphan the rest of its body at root.
      pseudo_depth = 0
      while i < tokens.size
        tok = tokens[i]
        if tok.kind == Token::Kind::Keyword
          case tok.text
          when "end"
            if pseudo_depth > 0
              pseudo_depth -= 1
            elsif node = stack.pop?
              node.end_token = tok
            end
          when "class", "module", "struct", "enum", "lib", "annotation"
            node = build_type_symbol(tokens, i, tok)
            if node
              attach(node, stack, roots)
              stack << node unless tok.text == "enum" && enum_is_single_line?(tokens, i)
              # enums can be written on a single line, but we treat them
              # like any other scope — the `end` token closes them.
            end
            abstract_modifier = false
          when "def", "macro"
            node = build_callable_symbol(tokens, i, tok)
            if node
              attach(node, stack, roots)
              # Abstract defs have no body / `end`; leaving them on the
              # stack would glom the enclosing class's body onto their
              # range, breaking call-hierarchy and any other handler
              # that walks `[opener .. end_token]`.
              if abstract_modifier
                node.end_token = node.name_token
              else
                stack << node
              end
            end
            abstract_modifier = false
          when "alias"
            if node = build_alias_symbol(tokens, i, tok)
              attach(node, stack, roots)
            end
            abstract_modifier = false
          when "abstract"
            abstract_modifier = true
          when "begin", "case", "do"
            # These always open a block that ends with `end`, never
            # postfix — safe to count unconditionally.
            pseudo_depth += 1
          when "if", "unless", "while", "until"
            # Block form when line-leading (`if cond\n ... end`), OR
            # when used as a value-expression RHS like `x = if ...`.
            # Postfix form (`x = 1 if cond`) has no matching `end` and
            # must not increment. Heuristic: treat line-leading plus
            # the `= / ( / , / return` lead-ins as block form.
            pseudo_depth += 1 if block_opener?(tokens, i)
          when "private", "protected"
            # modifier only
          else
            abstract_modifier = false
          end
        elsif tok.kind == Token::Kind::Constant && constant_assignment?(tokens, i)
          node = SymbolNode.new(
            name: tok.text,
            kind: Protocol::SymbolKind::CONSTANT,
            opener: tok,
            name_token: tok,
          )
          node.end_token = tok
          attach(node, stack, roots)
        elsif tok.kind == Token::Kind::Constant && enum_member?(tokens, i, stack)
          # Bare Constant sitting at the start of a line inside an enum
          # scope — an enum member. The scanner doesn't see the later
          # `=` / parens, so we treat any line-leading Constant inside
          # an enum as a member. Enum members show up in goto/hover
          # as `Mode::Spruce` once the index qualifies them.
          node = SymbolNode.new(
            name: tok.text,
            kind: Protocol::SymbolKind::ENUM_MEMBER,
            opener: tok,
            name_token: tok,
          )
          node.end_token = tok
          attach(node, stack, roots)
        end
        i += 1
      end

      # Any still-open scopes get the end of file as their end token.
      while node = stack.pop?
        node.end_token = tokens.last?
      end

      roots
    end

    # Crystal specs declare examples with a top-level call —
    # `it "name" do … end`, `describe "thing" do … end`,
    # `context "when …" do … end`. These aren't `def`s, so the
    # callable-symbol extractor above skips them. For the "▶ Run"
    # CodeLens we scan the token stream directly, picking out every
    # line-leading call to one of the three DSL verbs followed by a
    # string literal name.
    SPEC_VERBS = {"it", "describe", "context"}

    struct SpecExample
      getter name : String
      getter verb_token : Token

      def initialize(@name, @verb_token)
      end
    end

    # Callers pass the already-scanned token stream (e.g. `doc.tokens`)
    # so we don't re-tokenize the buffer for every CodeLens request.
    def spec_examples(tokens : Array(Token)) : Array(SpecExample)
      examples = [] of SpecExample
      i = 0
      while i < tokens.size
        tok = tokens[i]
        if tok.kind == Token::Kind::Identifier &&
           SPEC_VERBS.includes?(tok.text) &&
           line_leading?(tokens, i)
          if name_tok = spec_name_string(tokens, i + 1)
            examples << SpecExample.new(
              name: unquote_string_literal(name_tok.text),
              verb_token: tok,
            )
          end
        end
        i += 1
      end
      examples
    end

    # True when the `Constant` token at `tokens[i]` is the left-hand
    # side of a constant assignment — `FOO = expr` at statement
    # position — as opposed to a usage (`Foo.new`, `foo(FOO)`). Must be
    # line-leading and the very next non-whitespace token must be a
    # single `=` (not `==`, `===`, `=>`).
    private def constant_assignment?(tokens, i) : Bool
      return false unless line_leading?(tokens, i)
      j = i + 1
      while j < tokens.size
        t = tokens[j]
        case t.kind
        when Token::Kind::Whitespace, Token::Kind::Newline
          j += 1
        when Token::Kind::Operator
          return t.text == "="
        else
          return false
        end
      end
      false
    end

    # True if only whitespace separates `tokens[i]` from the start of
    # the line (or the start of file). Keeps `it` in `foo.it "x"` from
    # registering as a spec example.
    # True when the `if`/`unless`/`while`/`until` at `tokens[i]` is
    # the block-form `if ... end` rather than postfix `expr if cond`.
    # Block form lives at line start, or follows `=` / `(` / `[` / `,`
    # / `return` / `&&` / `||` / `?` — contexts where a value-producing
    # expression is expected.
    private def block_opener?(tokens, i) : Bool
      return true if line_leading?(tokens, i)
      j = i - 1
      while j >= 0
        t = tokens[j]
        case t.kind
        when Token::Kind::Whitespace, Token::Kind::Newline
          j -= 1
        else
          return block_lead_in?(t)
        end
      end
      true
    end

    private def block_lead_in?(tok : Token) : Bool
      case tok.kind
      when Token::Kind::Operator
        {"=", "(", "[", ",", "&&", "||", "?", "+=", "-=", "||=", "&&=", ":"}.includes?(tok.text)
      when Token::Kind::Keyword
        {"return", "yield", "then", "else", "when", "do", "begin", "in"}.includes?(tok.text)
      else
        false
      end
    end

    private def enum_member?(tokens, i, stack) : Bool
      return false unless line_leading?(tokens, i)
      parent = stack.last?
      return false unless parent
      parent.kind == Protocol::SymbolKind::ENUM
    end

    private def line_leading?(tokens, i) : Bool
      j = i - 1
      while j >= 0
        case tokens[j].kind
        when Token::Kind::Whitespace then j -= 1
        when Token::Kind::Newline    then return true
        else                              return false
        end
      end
      true
    end

    # Walk forward from `from` looking for the string literal that
    # names the example. Accept a leading `(` — `it("foo") do` is the
    # parenthesized form of the same DSL call.
    private def spec_name_string(tokens, from : Int32) : Token?
      j = from
      while j < tokens.size
        t = tokens[j]
        case t.kind
        when Token::Kind::Whitespace, Token::Kind::Newline
          j += 1
        when Token::Kind::Punctuation
          return nil unless t.text == "("
          j += 1
        when Token::Kind::String
          return t
        else
          return nil
        end
      end
      nil
    end

    # Turn the raw token text (including the surrounding quotes and
    # any backslash escapes) into the literal string. We only unescape
    # the two escapes that can appear in a quote-delimited name; the
    # rest pass through untouched, which is fine — `crystal spec -e`
    # treats the argument as a substring anyway.
    private def unquote_string_literal(raw : String) : String
      return raw if raw.bytesize < 2
      first = raw[0]
      last = raw[-1]
      return raw unless (first == '"' || first == '\'') && last == first
      inner = raw[1...-1]
      inner.gsub("\\\\", "\x00").gsub("\\\"", "\"").gsub("\x00", "\\")
    end

    # Find the identifier-like word containing `byte_offset` (or abutting
    # it on the right). Returns nil for whitespace / operator zones.
    def word_at(source : String, byte_offset : Int32) : String?
      return nil if byte_offset < 0 || byte_offset > source.bytesize

      start = byte_offset
      while start > 0
        ch = source.byte_at(start - 1).unsafe_chr
        break unless identifier_char?(ch)
        start -= 1
      end

      first_is_upper = start < source.bytesize &&
                       source.byte_at(start).unsafe_chr.ascii_uppercase?

      stop = byte_offset
      while stop < source.bytesize
        ch = source.byte_at(stop).unsafe_chr
        break unless identifier_char?(ch)
        break if first_is_upper && (ch == '?' || ch == '!')
        stop += 1
      end

      return nil if start == stop
      source.byte_slice(start, stop - start)
    end

    def identifier_char?(ch : Char) : Bool
      ch.ascii_alphanumeric? || ch == '_' || ch == '?' || ch == '!'
    end

    # Like `word_at`, but skips Crystal keywords and attaches any
    # `@` / `@@` / `$` sigil present in the source. The typical reason
    # for the keyword skip: the cursor landed on whitespace right after
    # `class` / `def` / `enum`, and `word_at` extended backward into
    # the keyword. Returns nil when no user identifier is reachable on
    # the same line.
    def user_identifier_at(source : String, byte_offset : Int32) : String?
      w = word_at(source, byte_offset)
      return extend_with_sigils(source, byte_offset, w) if w && !KEYWORDS.includes?(w)

      i = byte_offset
      while i < source.bytesize
        ch = source.byte_at(i).unsafe_chr
        break if ch == '\n'
        if identifier_char?(ch)
          candidate = word_at(source, i)
          return extend_with_sigils(source, i, candidate) if candidate && !KEYWORDS.includes?(candidate)
          while i < source.bytesize && identifier_char?(source.byte_at(i).unsafe_chr)
            i += 1
          end
        else
          i += 1
        end
      end
      nil
    end

    def strip_sigils(name : String) : String
      name.lchop('@').lchop('@').lchop('$')
    end

    # True when `name` appears as the LHS of an assignment or as an
    # argument inside `scope`'s token range. Used by references (and
    # definition) to tell "local variable" apart from "method call" —
    # the former can't leak across files, the latter can.
    #
    # Heuristic: a non-`::` / non-`.`-prefixed identifier followed
    # (past whitespace) by `=` that isn't `==` / `>=` / `<=` / `!=` is
    # a binding. Parameter / block-arg names are trickier to isolate
    # from method calls, so we also accept a match anywhere within the
    # def's *first line* (signature), which covers `def foo(cc : X)`
    # and `def foo(&block)` without needing to parse the arg list.
    # True when `name` appears as the LHS of an assignment anywhere in
    # the token stream. Used as a coarser-grained locality check for
    # refs that don't sit inside a def (e.g. inside a `describe` block
    # in a spec file) — those refs can't be analyzed with the per-def
    # `locally_bound?` path but still need a way to tell "this is a
    # local binding" from "this is a method call."
    def bound_anywhere?(tokens : Array(Token), name : String) : Bool
      tokens.each_with_index do |tok, i|
        next unless tok.kind == Token::Kind::Identifier
        next unless tok.text == name
        prev = previous_non_whitespace(tokens, i)
        next if prev && (prev.text == "." || prev.text == "::")
        nxt = next_non_whitespace(tokens, i)
        if nxt && nxt.text == "=" && nxt.kind == Token::Kind::Operator
          after = tokens[tokens.index(nxt).not_nil! + 1]?
          # `a == b` tokenizes as two `=` ops — skip those.
          return true unless after && after.text == "="
        end
      end
      false
    end

    def locally_bound?(tokens : Array(Token), scope : SymbolNode, name : String) : Bool
      start_line = scope.opener.line
      end_line = scope.end_token.try(&.line) || start_line
      signature_line = scope.name_token.line
      def_name_byte = scope.name_token.byte_start

      tokens.each_with_index do |tok, i|
        next unless tok.line >= start_line && tok.line <= end_line
        next unless tok.kind == Token::Kind::Identifier
        next unless tok.text == name
        # The def's own name token sits on the signature line too but
        # isn't a binding — skip it so `findReferences` on `def foo`
        # doesn't narrow to the body.
        next if tok.byte_start == def_name_byte

        # Any other occurrence on the def's signature line is treated
        # as a parameter / block-arg introduction — good enough for
        # `def foo(cc)` without parsing the arg list.
        return true if tok.line == signature_line

        # Preceding `.` / `::` means this is a method call on a receiver,
        # not a local binding.
        prev = previous_non_whitespace(tokens, i)
        next if prev && (prev.text == "." || prev.text == "::")

        # Followed by `=` (and not `==` / similar) → assignment target.
        nxt = next_non_whitespace(tokens, i)
        if nxt && nxt.text == "=" && nxt.kind == Token::Kind::Operator
          after = tokens[tokens.index(nxt).not_nil! + 1]?
          return true unless after && after.text == "="
        end
      end
      false
    end

    def previous_non_whitespace(tokens : Array(Token), i : Int32) : Token?
      j = i - 1
      while j >= 0
        t = tokens[j]
        return t unless t.kind.whitespace? || t.kind.newline?
        j -= 1
      end
      nil
    end

    def next_non_whitespace(tokens : Array(Token), i : Int32) : Token?
      j = i + 1
      while j < tokens.size
        t = tokens[j]
        return t unless t.kind.whitespace? || t.kind.newline?
        j += 1
      end
      nil
    end

    # Collect any `Outer::Inner::` qualifier that textually precedes the
    # word at `byte_offset`. Returns the fully qualified form if the
    # word is prefixed by one or more `::`-separated segments,
    # otherwise returns nil so callers can fall through to the bare
    # lookup. Used to disambiguate `Mode::Spruce` from an unrelated
    # top-level `class Spruce`.
    def qualified_name_at(source : String, byte_offset : Int32) : String?
      word = word_at(source, byte_offset)
      return nil unless word

      word_start = byte_offset
      while word_start > 0 && identifier_char?(source.byte_at(word_start - 1).unsafe_chr)
        word_start -= 1
      end

      segments = [word]
      pos = word_start
      while pos >= 2 &&
            source.byte_at(pos - 1).unsafe_chr == ':' &&
            source.byte_at(pos - 2).unsafe_chr == ':'
        qual_end = pos - 2
        qual_start = qual_end
        while qual_start > 0 && identifier_char?(source.byte_at(qual_start - 1).unsafe_chr)
          qual_start -= 1
        end
        break if qual_start == qual_end
        segments.unshift(source.byte_slice(qual_start, qual_end - qual_start))
        pos = qual_start
      end

      segments.size == 1 ? nil : segments.join("::")
    end

    # Walk a symbol tree and return the innermost METHOD/FUNCTION
    # node whose line range contains `line`. Used by handlers that
    # need "which def am I in" (definition's local-binding fast path,
    # call hierarchy's caller grouping).
    def enclosing_callable(roots : Array(SymbolNode), line : Int32) : SymbolNode?
      roots.each do |n|
        next unless node_spans_line?(n, line)
        if inner = enclosing_callable(n.children, line)
          return inner
        end
        return n if n.kind == Protocol::SymbolKind::METHOD || n.kind == Protocol::SymbolKind::FUNCTION
      end
      nil
    end

    # Walk a symbol tree and return the innermost CLASS/STRUCT/MODULE
    # node whose line range contains `line`. Mirrors
    # `enclosing_callable` but for type-kind scopes.
    def enclosing_type(roots : Array(SymbolNode), line : Int32) : SymbolNode?
      found : SymbolNode? = nil
      roots.each do |n|
        next unless node_spans_line?(n, line)
        if inner = enclosing_type(n.children, line)
          found = inner
        end
        kind = n.kind
        if found.nil? && (kind == Protocol::SymbolKind::CLASS ||
           kind == Protocol::SymbolKind::STRUCT ||
           kind == Protocol::SymbolKind::MODULE)
          found = n
        end
        return found if found
      end
      found
    end

    private def node_spans_line?(node : SymbolNode, line : Int32) : Bool
      start_line = node.opener.line
      end_line = node.end_token.try(&.line) || node.name_token.line
      line >= start_line && line <= end_line
    end

    # Canonicalize a compiler-reported type string down to a bare
    # lookup name: drop generic args (`Array(Int32)` → `Array`), the
    # virtual `+` suffix (`Foo+` → `Foo`), and pick the first arm of
    # a union (`Int32 | Nil` → `Int32`). Used by completion and
    # type-definition for workspace-index lookups.
    def strip_type(type_str : String) : String
      first = type_str.split('|').first.strip
      if idx = first.index('(')
        first = first[0...idx]
      end
      first.rchop('+').strip
    end

    # Given the byte offset of a word inside `source`, extend the word
    # backwards across any `@` / `@@` / `$` sigils that prefix it.
    # Used by references, rename, and highlight so that a cursor on
    # `ivar` in `@ivar` resolves the full `@ivar` name.
    def extend_with_sigils(source : String, byte_offset : Int32, word : String) : String
      start = byte_offset
      while start > 0 && identifier_char?(source.byte_at(start - 1).unsafe_chr)
        start -= 1
      end
      prefix = ""
      if start > 0 && source.byte_at(start - 1).unsafe_chr.in?('@', '$')
        prefix = source.byte_at(start - 1).unsafe_chr.to_s
        if prefix == "@" && start > 1 && source.byte_at(start - 2).unsafe_chr == '@'
          prefix = "@@"
        end
      end
      prefix + word
    end

    # --- internal helpers ---------------------------------------------

    private def attach(node, stack, roots)
      if parent = stack.last?
        parent.children << node
        node.parent = parent
      else
        roots << node
      end
    end

    private def build_type_symbol(tokens, i, keyword_tok) : SymbolNode?
      name_tok = skip_to_identifier(tokens, i + 1)
      return nil unless name_tok
      qual = qualified_name_with_tail(tokens, name_tok[:index])

      # Capture the opener line as detail so TypeHierarchy / Implementation
      # can read `class Foo < Bar` off the node without re-tokenizing.
      raw_sig = String.build do |io|
        io << keyword_tok.text << ' '
        j = i + 1
        depth = 0
        while j < tokens.size
          t = tokens[j]
          break if t.kind == Token::Kind::Newline && depth == 0
          case t.text
          when "(" then depth += 1
          when ")" then depth -= 1
          end
          io << t.text
          j += 1
        end
      end
      sig = raw_sig.gsub(/\s+/, " ").strip

      SymbolNode.new(
        name: qual[:name],
        kind: type_symbol_kind(keyword_tok.text),
        opener: keyword_tok,
        # Point at the last segment of a qualified name so goto lands
        # on `Vec3i` in `struct Rosegold::Vec3i`, not on `Rosegold`.
        name_token: qual[:last],
        detail: sig,
      )
    end

    private def build_callable_symbol(tokens, i, keyword_tok) : SymbolNode?
      name_tok = skip_to_identifier(tokens, i + 1, allow_self: true)
      return nil unless name_tok

      # `def self.name` / `def SomeType.name`: the first identifier we
      # hit is the receiver, not the method name. Skip the `.` and
      # take the next identifier as the real name_token so
      # goto/highlight land on `name`, not on `self`.
      if tokens[name_tok[:index] + 1]?.try(&.text) == "."
        if method_tok = skip_to_identifier(tokens, name_tok[:index] + 2)
          name_tok = method_tok
        end
      end

      # Capture the whole signature line up to the newline: the name,
      # arg list, and any `: ReturnType` annotation. Multi-line arg
      # lists are folded to single spaces so the completion popup
      # shows `def foo(x : Int32) : Bool`, not the raw source with
      # stray newlines inside parameter lists.
      raw_sig = String.build do |io|
        io << keyword_tok.text << ' '
        j = i + 1
        depth = 0
        while j < tokens.size
          t = tokens[j]
          break if t.kind == Token::Kind::Newline && depth == 0
          case t.text
          when "(" then depth += 1
          when ")" then depth -= 1
          end
          io << t.text
          j += 1
        end
      end
      sig = raw_sig.gsub(/\s+/, " ").strip

      SymbolNode.new(
        name: name_tok[:token].text,
        kind: keyword_tok.text == "macro" ? Protocol::SymbolKind::FUNCTION : Protocol::SymbolKind::METHOD,
        opener: keyword_tok,
        name_token: name_tok[:token],
        detail: sig.strip,
      )
    end

    private def build_alias_symbol(tokens, i, keyword_tok) : SymbolNode?
      name_tok = skip_to_identifier(tokens, i + 1)
      return nil unless name_tok
      node = SymbolNode.new(
        name: name_tok[:token].text,
        kind: Protocol::SymbolKind::TYPE_PARAMETER,
        opener: keyword_tok,
        name_token: name_tok[:token],
      )
      # alias is a one-liner — close it on the same line's last non-newline token.
      j = name_tok[:index]
      while j < tokens.size && tokens[j].kind != Token::Kind::Newline
        j += 1
      end
      node.end_token = tokens[j - 1]? || keyword_tok
      node
    end

    private def type_symbol_kind(keyword : String) : Int32
      case keyword
      when "class"      then Protocol::SymbolKind::CLASS
      when "struct"     then Protocol::SymbolKind::STRUCT
      when "module"     then Protocol::SymbolKind::MODULE
      when "enum"       then Protocol::SymbolKind::ENUM
      when "lib"        then Protocol::SymbolKind::NAMESPACE
      when "annotation" then Protocol::SymbolKind::INTERFACE
      else                   Protocol::SymbolKind::CLASS
      end
    end

    private def skip_to_identifier(tokens, from : Int32, allow_self : Bool = false) : NamedTuple(index: Int32, token: Token)?
      j = from
      while j < tokens.size
        t = tokens[j]
        case t.kind
        when Token::Kind::Whitespace, Token::Kind::Newline then j += 1
        when Token::Kind::Identifier, Token::Kind::Constant
          return {index: j, token: t}
        when Token::Kind::Keyword
          return {index: j, token: t} if allow_self && t.text == "self"
          return nil
        else
          return nil
        end
      end
      nil
    end

    private def qualified_name(tokens, name_index) : String
      qualified_name_with_tail(tokens, name_index)[:name]
    end

    # Like `qualified_name`, but also returns the token of the final
    # segment. Callers that set `name_token` need this so goto /
    # highlight ranges land on the actual type name, not on the
    # namespace prefix.
    private def qualified_name_with_tail(tokens, name_index) : NamedTuple(name: String, last: Token)
      result = tokens[name_index].text
      last = tokens[name_index]
      j = name_index + 1
      while j + 1 < tokens.size && tokens[j].text == "::"
        result += "::" + tokens[j + 1].text
        last = tokens[j + 1]
        j += 2
      end
      {name: result, last: last}
    end

    private def enum_is_single_line?(tokens, i) : Bool
      line = tokens[i].line
      # Very conservative — if `end` appears on the same line, treat as single.
      j = i + 1
      while j < tokens.size && tokens[j].line == line
        return true if tokens[j].text == "end"
        j += 1
      end
      false
    end

    # ------------------------------------------------------------------

    class SymbolNode
      property name : String
      property kind : Int32
      property opener : Token
      property name_token : Token
      property end_token : Token?
      property detail : String?
      property children : Array(SymbolNode)
      property parent : SymbolNode?

      def initialize(@name, @kind, @opener, @name_token, @detail = nil)
        @children = [] of SymbolNode
      end
    end

    # ==================================================================
    # Reader — character-by-character tokenizer. Private implementation.
    # ==================================================================

    private class Reader
      @pos : Int32
      @line : Int32
      @column : Int32

      def initialize(@source : String)
        @pos = 0
        @line = 0
        @column = 0
      end

      def next_token : Token?
        return nil if eof?
        start_pos = @pos
        start_line = @line
        start_col = @column
        ch = current

        case ch
        when '\n'
          advance
          Token.new(Token::Kind::Newline, "\n", start_pos, @pos, start_line, start_col)
        when ' ', '\t', '\r'
          while !eof? && (current == ' ' || current == '\t' || current == '\r')
            advance
          end
          Token.new(Token::Kind::Whitespace, @source.byte_slice(start_pos, @pos - start_pos),
            start_pos, @pos, start_line, start_col)
        when '#'
          while !eof? && current != '\n'
            advance
          end
          Token.new(Token::Kind::Comment, @source.byte_slice(start_pos, @pos - start_pos),
            start_pos, @pos, start_line, start_col)
        when '"'
          read_string('"', start_pos, start_line, start_col)
        when '\''
          read_char(start_pos, start_line, start_col)
        when ':'
          read_colon_or_symbol(start_pos, start_line, start_col)
        when '@'
          read_ivar(start_pos, start_line, start_col)
        when '$'
          read_global(start_pos, start_line, start_col)
        else
          if ch.ascii_number?
            read_number(start_pos, start_line, start_col)
          elsif ch.ascii_letter? || ch == '_'
            read_identifier(start_pos, start_line, start_col)
          elsif ch == '<' && peek(1) == '<' && (peek(2) == '-' || peek(2) == '~')
            read_heredoc(start_pos, start_line, start_col)
          else
            read_punctuation(start_pos, start_line, start_col)
          end
        end
      end

      # --- readers ----------------------------------------------------

      private def read_string(quote : Char, sp, sl, sc)
        advance # opening quote
        until eof?
          c = current
          if c == '\\'
            advance
            advance unless eof?
          elsif c == '#' && peek(1) == '{'
            # skip interpolation, respecting nested braces
            advance; advance
            depth = 1
            while !eof? && depth > 0
              case current
              when '{' then depth += 1
              when '}' then depth -= 1
              end
              advance
            end
          elsif c == quote
            advance
            break
          else
            advance
          end
        end
        Token.new(Token::Kind::String, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
      end

      private def read_char(sp, sl, sc)
        advance
        if !eof? && current == '\\'
          advance
          advance unless eof?
        elsif !eof?
          advance
        end
        advance if !eof? && current == '\''
        Token.new(Token::Kind::Char, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
      end

      private def read_colon_or_symbol(sp, sl, sc)
        if peek(1) == ':'
          advance; advance
          return Token.new(Token::Kind::Operator, "::", sp, @pos, sl, sc)
        end
        advance
        if !eof? && (current.ascii_letter? || current == '_')
          while !eof? && Scanner.identifier_char?(current)
            advance
          end
          Token.new(Token::Kind::Symbol, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
        elsif !eof? && current == '"'
          read_string('"', sp, sl, sc)
          # leading ':' already consumed; treat as symbol
          Token.new(Token::Kind::Symbol, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
        else
          Token.new(Token::Kind::Punctuation, ":", sp, @pos, sl, sc)
        end
      end

      private def read_ivar(sp, sl, sc)
        advance
        advance if !eof? && current == '@'
        while !eof? && Scanner.identifier_char?(current)
          advance
        end
        txt = @source.byte_slice(sp, @pos - sp)
        kind = txt.starts_with?("@@") ? Token::Kind::CVar : Token::Kind::IVar
        Token.new(kind, txt, sp, @pos, sl, sc)
      end

      private def read_global(sp, sl, sc)
        advance
        while !eof? && Scanner.identifier_char?(current)
          advance
        end
        Token.new(Token::Kind::Global, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
      end

      private def read_number(sp, sl, sc)
        while !eof? && (current.ascii_number? || current == '_' || current == '.' || current == 'e' || current == 'E' ||
              current == 'x' || current == 'o' || current == 'b' ||
              (current >= 'a' && current <= 'f') || (current >= 'A' && current <= 'F') ||
              current == 'i' || current == 'u' || current == 'f')
          advance
        end
        Token.new(Token::Kind::Number, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
      end

      private def read_identifier(sp, sl, sc)
        first_is_upper = !eof? && current.ascii_uppercase?
        while !eof? && Scanner.identifier_char?(current)
          # Uppercase-leading identifiers are types/constants; `?` / `!`
          # after them are the nilable-type suffix (`Foo?`) or a negated
          # call (`Foo!`), not part of the name. Stopping here keeps
          # `BotCoordinator` findable as a reference target in
          # `property x : BotCoordinator?`.
          break if first_is_upper && (current == '?' || current == '!')
          advance
        end
        text = @source.byte_slice(sp, @pos - sp)
        kind =
          if KEYWORDS.includes?(text)
            Token::Kind::Keyword
          elsif text[0].ascii_uppercase?
            Token::Kind::Constant
          else
            Token::Kind::Identifier
          end
        Token.new(kind, text, sp, @pos, sl, sc)
      end

      private def read_heredoc(sp, sl, sc)
        # <<-FOO or <<~FOO ... FOO
        advance; advance; advance # consume <<- or <<~
        tag_start = @pos
        while !eof? && (current.ascii_letter? || current.ascii_number? || current == '_')
          advance
        end
        tag = @source.byte_slice(tag_start, @pos - tag_start)
        # Skip to the end tag on its own line. Cheap approximation.
        while !eof?
          if current == '\n'
            advance
            # skip leading whitespace
            line_start = @pos
            while !eof? && (current == ' ' || current == '\t')
              advance
            end
            if @source.byte_slice(@pos, {tag.bytesize, @source.bytesize - @pos}.min) == tag
              @pos += tag.bytesize
              break
            end
            @pos = line_start # no tag found, keep consuming
          end
          break if eof?
          advance
        end
        Token.new(Token::Kind::String, @source.byte_slice(sp, @pos - sp), sp, @pos, sl, sc)
      end

      private def read_punctuation(sp, sl, sc)
        ch = current
        advance
        # Try to form multi-char operators (==, !=, <=, >=, <<, >>, &&, ||, ...)
        if !eof?
          two = @source.byte_slice(sp, 2)
          case two
          when "==", "!=", "<=", ">=", "<<", ">>", "&&", "||", "=>", "->", "..", "**", "+=", "-=", "*=", "/=", "%=", "|=", "&=", "^="
            advance
            return Token.new(Token::Kind::Operator, two, sp, @pos, sl, sc)
          end
        end
        kind = ch.in?('(', ')', '[', ']', '{', '}', ',', ';', '.') ? Token::Kind::Punctuation : Token::Kind::Operator
        Token.new(kind, ch.to_s, sp, @pos, sl, sc)
      end

      # --- low-level I/O ---------------------------------------------

      private def current : Char
        @source.byte_at(@pos).unsafe_chr
      end

      private def peek(offset : Int32) : Char
        return '\0' if @pos + offset >= @source.bytesize
        @source.byte_at(@pos + offset).unsafe_chr
      end

      private def advance : Nil
        return if eof?
        ch = current
        @pos += 1
        if ch == '\n'
          @line += 1
          @column = 0
        else
          @column += 1
        end
      end

      private def eof? : Bool
        @pos >= @source.bytesize
      end
    end
  end
end
