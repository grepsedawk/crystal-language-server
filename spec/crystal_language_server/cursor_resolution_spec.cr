require "../spec_helper"

include CrystalLanguageServer

describe "cursor identifier resolution" do
  describe "Scanner.user_identifier_at" do
    it "returns the next identifier when cursor lands on a keyword" do
      source = "  enum Mode\n    Foo\n  end\n"
      # cursor on the trailing space of `enum` (index 6): word_at
      # extends backward to `enum`; user_identifier_at advances to
      # `Mode`.
      Scanner.user_identifier_at(source, 6).should eq "Mode"
    end

    it "returns a user identifier directly when the cursor is inside it" do
      source = "class BotCoordinator\nend\n"
      # index 11 is the second `o` in `BotCoordinator`.
      Scanner.user_identifier_at(source, 11).should eq "BotCoordinator"
    end

    it "resolves abstract def names across the keyword chain" do
      source = "  abstract def mode : Mode\n"
      # index 11 is the `d` in `def` — user_identifier_at should
      # advance past the keyword and land on `mode`.
      Scanner.user_identifier_at(source, 11).should eq "mode"
    end

    it "attaches a leading sigil when one is present" do
      source = "class Foo\n  @counter = 0\nend\n"
      # offset of `c` in `counter`
      offset = source.index!("counter")
      Scanner.user_identifier_at(source, offset).should eq "@counter"
    end

    it "returns nil when cursor is on the @ sigil itself and produces @name" do
      source = "class Foo\n  @ivar = 1\nend\n"
      offset = source.index!('@')
      Scanner.user_identifier_at(source, offset).should eq "@ivar"
    end

    it "returns nil when there's no identifier on the line at or after the cursor" do
      source = "       \n    x = 1\n"
      # cursor on the leading whitespace of a blank line.
      Scanner.user_identifier_at(source, 3).should be_nil
    end
  end

  describe "References.handle" do
    it "narrows references for a locally-bound name to the enclosing def" do
      uri_a = "file:///scope-a.cr"
      uri_b = "file:///scope-b.cr"
      source_a = <<-CR
        class A
          def run(cc)
            cc.first
            cc
          end
        end
        CR
      source_b = <<-CR
        class B
          def other
            cc = 1
            cc
          end
        end
        CR

      ws = Workspace.new(Options.new)
      ws.documents.open(uri_a, source_a, 1, "crystal")
      ws.documents.open(uri_b, source_b, 1, "crystal")

      # Cursor inside `cc` (line 2 inside `def run`), ~col 5.
      params = JSON.parse(%({
        "textDocument": {"uri": #{uri_a.to_json}},
        "position": {"line": 2, "character": 5},
        "context": {"includeDeclaration": true}
      }))
      result = Handlers::References.handle(ws, params)
      result.should_not be_nil
      raise "unreachable" unless result
      locs = result.as(Array)
      locs.all? { |l| l[:uri] == uri_a }.should be_true
    ensure
      WorkspaceIndex.invalidate_all
    end

    it "finds references when cursor lands on the whitespace after `enum`" do
      uri = "file:///cursor-refs-enum.cr"
      source = <<-CR
        enum Mode
          Foo
        end

        m = Mode::Foo
        other = Mode::Foo
        CR
      ws = ws_with_doc(uri, source)

      # Line 0 is `enum Mode`; col 4 is the space between `enum` and
      # `Mode`. Previously this resolved to the keyword `enum` and
      # returned zero references.
      params = JSON.parse(%({
        "textDocument": {"uri": #{uri.to_json}},
        "position": {"line": 0, "character": 4},
        "context": {"includeDeclaration": true}
      }))
      result = Handlers::References.handle(ws, params)
      result.should_not be_nil
      raise "unreachable" unless result
      locs = result.as(Array)
      locs.size.should be >= 3 # declaration + 2 usages


    ensure
      WorkspaceIndex.invalidate_all
    end
  end
end
