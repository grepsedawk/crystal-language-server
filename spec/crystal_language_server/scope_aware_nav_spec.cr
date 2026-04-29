require "../spec_helper"
require "file_utils"

include CrystalLanguageServer

private def goto_params(uri : String, line : Int32, character : Int32) : JSON::Any
  JSON.parse(%({
    "textDocument": {"uri": #{uri.to_json}},
    "position": {"line": #{line}, "character": #{character}}
  }))
end

describe "scope-aware navigation" do
  it "scanner tags enum members and indexes them as EnumName::Member" do
    source = <<-CR
      enum Mode
        Spruce
        Oak
      end
      CR

    roots = Scanner.document_symbols(source)
    mode = roots.find { |n| n.name == "Mode" }.not_nil!
    mode.children.map(&.name).should contain("Spruce")
    mode.children.find { |n| n.name == "Spruce" }.not_nil!.kind.should eq Protocol::SymbolKind::ENUM_MEMBER
  end

  it "Definition resolves `Mode::Spruce` to the enum member, not an unrelated class" do
    uri = "file:///enum-goto.cr"
    source = <<-CR
      enum Mode
        Spruce
        Oak
      end

      class Spruce
      end

      x = Mode::Spruce
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    # `Mode::Spruce` is on the last line; cursor inside `Spruce`.
    line = source.lines.index! { |l| l.includes?("Mode::Spruce") }
    col = source.lines[line].index!("Spruce")
    result = Handlers::Definition.handle(ws, goto_params(uri, line, col + 2))
    result.should_not be_nil
    raise "unreachable" unless result

    locs = result.as(Array)
    locs.size.should eq 1
    # The enum member is on line 1 (0-based); the class is on line 5.
    locs.first[:range].start.line.should eq 1
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "Definition on @ivar jumps to the first matching ivar token, not a same-named method" do
    uri = "file:///ivar-goto.cr"
    source = <<-CR
      class Parent
        def bot
          "parent_bot"
        end
      end

      class Child
        @bot : Int32 = 0

        def describe
          @bot.to_s
        end
      end
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    # Cursor on the `@bot` inside `@bot.to_s` (line 10, first @).
    target_line = source.lines.index! { |l| l.includes?("@bot.to_s") }
    col = source.lines[target_line].index!("@bot")
    result = Handlers::Definition.handle(ws, goto_params(uri, target_line, col + 1))
    result.should_not be_nil
    raise "unreachable" unless result
    locs = result.as(Array)
    # First @bot token is the ivar declaration on line 7.
    locs.first[:range].start.line.should eq 7
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "scanner bounds abstract defs to the def line, not the enclosing class body" do
    source = <<-CR
      abstract class Base
        abstract def perform : String

        def other
          body_here
        end
      end
      CR

    roots = Scanner.document_symbols(source)
    base = roots.find { |n| n.name == "Base" }.not_nil!
    perform = base.children.find { |n| n.name == "perform" }.not_nil!
    # `end_token` should be the perform name token (the def has no body),
    # NOT the enclosing class `end`.
    perform.end_token.not_nil!.line.should eq 1
  end

  it "scanner names `def self.name` as `name`, not `self`" do
    source = "class Foo\n  def self.bar\n  end\nend\n"
    roots = Scanner.document_symbols(source)
    foo = roots.find { |n| n.name == "Foo" }.not_nil!
    foo.children.map(&.name).should contain("bar")
    foo.children.map(&.name).should_not contain("self")
  end

  it "indexes nested types under their qualified name" do
    uri = "file:///nested-types.cr"
    source = <<-CR
      module Rosegold
        class Bot
        end
      end

      x = Rosegold::Bot.new
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    # Cursor inside `Bot` of `Rosegold::Bot` on the last line.
    target_line = source.lines.size - 1
    col = source.lines[target_line].index!("Rosegold::Bot") + "Rosegold::".size + 1
    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "position": {"line": #{target_line}, "character": #{col}}
    }))
    result = Handlers::Definition.handle(ws, params)
    result.should_not be_nil
    raise "unreachable" unless result
    locs = result.as(Array)
    locs.size.should eq 1
    locs.first[:range].start.line.should eq 1
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "findReferences on a method decl drops local-bound bare usages but keeps implicit-self calls" do
    uri_a = "file:///method-vs-local-a.cr"
    uri_b = "file:///method-vs-local-b.cr"
    source_a = <<-CR
      class Owner
        def bot
          "owner"
        end
      end
      CR
    source_b = <<-CR
      class Stranger < Owner
        def unrelated
          bot = 1
          puts bot
        end

        def caller(x)
          x.bot
        end

        def implicit_self
          bot.upcase
        end
      end
      CR

    ws = Workspace.new(Options.new)
    ws.documents.open(uri_a, source_a, 1, "crystal")
    ws.documents.open(uri_b, source_b, 1, "crystal")

    line = source_a.lines.index! { |l| l.includes?("def bot") }
    col = source_a.lines[line].index!("bot") + 1
    params = JSON.parse(%({
      "textDocument": {"uri": #{uri_a.to_json}},
      "position": {"line": #{line}, "character": #{col}},
      "context": {"includeDeclaration": true}
    }))
    result = Handlers::References.handle(ws, params)
    result.should_not be_nil
    raise "unreachable" unless result
    locs = result.as(Array)
    # Expect: decl in a.cr, `x.bot` at line 7 of b.cr, and the bare
    # `bot.upcase` (implicit self) at line 11 of b.cr. The `bot = 1`
    # + `puts bot` pair in `unrelated` must not appear — their
    # enclosing def locally binds `bot`.
    locs.map { |l| {l[:uri], l[:range].start.line} }.sort.should eq [
      {uri_a, 1},
      {uri_b, 7},
      {uri_b, 11},
    ]
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "find_defs resolves a nested `Module::Type` even before the name index is warm" do
    dir = File.tempname("qualified-warm")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "nested.cr")
      File.write(path, "module Rosegold\n  class Bot\n  end\nend\n")

      ws = Workspace.new(Options.new)
      # Set root without opening a buffer — warm pass runs async.
      ws.root_path = dir
      # Deliberately DO NOT wait for warm; we want the fallback path.
      WorkspaceIndex.invalidate_all

      sites = WorkspaceIndex.find_defs(ws, "Rosegold::Bot")
      sites.size.should eq 1
      sites.first.file.should eq path
      sites.first.line.should eq 1
    ensure
      WorkspaceIndex.invalidate_all
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "findReferences on the def's own name token returns all callers (not local-scope only)" do
    uri_a = "file:///def-name-refs-a.cr"
    uri_b = "file:///def-name-refs-b.cr"
    source_a = <<-CR
      class Parent
        def bot
          "parent"
        end
      end
      CR
    source_b = <<-CR
      class Child
        def describe(other)
          other.bot
          other.bot.chars
        end
      end
      CR

    ws = Workspace.new(Options.new)
    ws.documents.open(uri_a, source_a, 1, "crystal")
    ws.documents.open(uri_b, source_b, 1, "crystal")

    # Cursor on the `bot` of `def bot` in uri_a (line 1, col ~6).
    line_a = source_a.lines.index! { |l| l.includes?("def bot") }
    col = source_a.lines[line_a].index!("bot") + 1
    params = JSON.parse(%({
      "textDocument": {"uri": #{uri_a.to_json}},
      "position": {"line": #{line_a}, "character": #{col}},
      "context": {"includeDeclaration": true}
    }))
    result = Handlers::References.handle(ws, params)
    result.should_not be_nil
    raise "unreachable" unless result
    locs = result.as(Array)
    # Should include refs from uri_b, not just uri_a.
    locs.any? { |l| l[:uri] == uri_b }.should be_true
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "CallHierarchy returns no outgoing calls for an abstract def" do
    uri = "file:///abstract-outgoing.cr"
    source = <<-CR
      abstract class Base
        abstract def perform : String
      end
      CR

    ws = ws_with_doc(uri, source)

    # Build a call-hierarchy item that points at the abstract def.
    # The range collapses to the signature line (start_line == end_line).
    item = {
      "name"           => "perform",
      "kind"           => 6, # METHOD
      "uri"            => uri,
      "range"          => {"start" => {"line" => 1, "character" => 2}, "end" => {"line" => 1, "character" => 30}},
      "selectionRange" => {"start" => {"line" => 1, "character" => 15}, "end" => {"line" => 1, "character" => 22}},
    }
    params = JSON.parse({"item" => item}.to_json)
    result = Handlers::CallHierarchy.outgoing_calls(ws, params)
    result.should be_empty
  end

  it "References on `Mode::Spruce` only returns qualified-match tokens" do
    uri = "file:///qualified-refs.cr"
    source = <<-CR
      enum Mode
        Spruce
      end

      class Spruce
      end

      a = Mode::Spruce
      b = Spruce.new
      c = Mode::Spruce
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    # Cursor on `Spruce` of `Mode::Spruce` on the last line.
    line = source.lines.size - 1
    col = source.lines[line].index!("Spruce") + 2
    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "position": {"line": #{line}, "character": #{col}},
      "context": {"includeDeclaration": true}
    }))
    result = Handlers::References.handle(ws, params)
    result.should_not be_nil
    raise "unreachable" unless result
    locs = result.as(Array)
    # Should get exactly 2 matches (line 7 + line 9), NOT the class
    # Spruce line and NOT `b = Spruce.new`.
    # declaration (line 1) + two qualified usages (lines 7, 9). The
    # bare `Spruce.new` on line 8 and the `class Spruce` on line 4
    # must NOT appear.
    locs.size.should eq 3
    locs.map(&.[:range].start.line).sort.should eq [1, 7, 9]
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "resolves a call to a private method in the same class" do
    uri = "file:///private-method-goto.cr"
    source = <<-CR
      class Xxx
        def xyz
          helper
        end

        private def helper
          42
        end
      end
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    call_line = source.lines.index! { |l| l.strip == "helper" }
    col = source.lines[call_line].index!("helper") + 2
    result = Handlers::Definition.handle(ws, goto_params(uri, call_line, col))
    result.should_not be_nil
    raise "unreachable" unless result
    locs = result.as(Array)
    decl_line = source.lines.index! { |l| l.includes?("private def helper") }
    locs.size.should eq 1
    locs.first[:range].start.line.should eq decl_line
  ensure
    WorkspaceIndex.invalidate_all
  end
end
