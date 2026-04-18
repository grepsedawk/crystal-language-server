require "../spec_helper"

private def doc_for(source : String) : CrystalLanguageServer::Document
  uri = "file:///tmp/organize_imports_spec.cr"
  ws_with_doc(uri, source).documents[uri]
end

private def organized_text(source : String) : String
  edits = CrystalLanguageServer::Handlers::OrganizeImports.edits_for(doc_for(source))
  return source if edits.empty?
  edit = edits.first
  lines = source.split('\n', remove_empty: false)
  before = lines[0, edit[:range].start.line]
  after = lines[edit[:range].end_.line..]
  prefix = before.empty? ? "" : before.join('\n') + "\n"
  prefix + edit[:newText] + after.join('\n')
end

describe CrystalLanguageServer::Handlers::OrganizeImports do
  it "sorts an unsorted leading require block" do
    source = <<-CR
      require "yaml"
      require "json"

      class Foo
      end
      CR
    organized_text(source).should eq <<-CR
      require "json"
      require "yaml"

      class Foo
      end
      CR
  end

  it "drops exact duplicate requires" do
    source = "require \"json\"\nrequire \"json\"\nrequire \"yaml\"\n"
    organized_text(source).should eq "require \"json\"\nrequire \"yaml\"\n"
  end

  it "returns no edits when the block is already sorted and unique" do
    source = <<-CR
      require "json"
      require "yaml"

      puts "hi"
      CR
    CrystalLanguageServer::Handlers::OrganizeImports.edits_for(doc_for(source)).should be_empty
  end

  it "buckets stdlib, then shards, then relative paths" do
    source = [
      %(require "./local"),
      %(require "rosegold"),
      %(require "yaml"),
      %(require "../sibling"),
      %(require "json"),
      %(require "some_shard"),
      "",
    ].join('\n')
    expected = [
      %(require "json"),
      %(require "yaml"),
      %(require "rosegold"),
      %(require "some_shard"),
      %(require "../sibling"),
      %(require "./local"),
      "",
    ].join('\n')
    organized_text(source).should eq expected
  end

  it "only touches the leading block — a blank line terminates it" do
    source = <<-CR
      require "yaml"
      require "json"

      require "zzz"
      CR
    organized_text(source).should eq <<-CR
      require "json"
      require "yaml"

      require "zzz"
      CR
  end

  it "returns no edits when the file does not start with a require" do
    source = <<-CR
      # copyright
      require "yaml"
      require "json"
      CR
    CrystalLanguageServer::Handlers::OrganizeImports.edits_for(doc_for(source)).should be_empty
  end
end

describe CrystalLanguageServer::Handlers::CodeAction do
  it "exposes a source.organizeImports action gated by `only`" do
    uri = "file:///tmp/organize_imports_action.cr"
    source = "require \"yaml\"\nrequire \"json\"\n"
    ws = ws_with_doc(uri, source)

    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":0}},
      "context": {"diagnostics": [], "only": ["source.organizeImports"]}
    }))
    actions = CrystalLanguageServer::Handlers::CodeAction.handle(ws, params)

    organize = actions.find { |a| a[:kind] == "source.organizeImports" }
    organize.should_not be_nil
    raise "unreachable" unless organize
    organize[:edit][:changes][uri].first[:newText].should eq "require \"json\"\nrequire \"yaml\"\n"
  end

  it "skips source.organizeImports when `only` does not request it" do
    uri = "file:///tmp/organize_imports_skip.cr"
    ws = ws_with_doc(uri, "require \"yaml\"\nrequire \"json\"\n")

    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":0}},
      "context": {"diagnostics": [], "only": ["quickfix"]}
    }))
    actions = CrystalLanguageServer::Handlers::CodeAction.handle(ws, params)
    actions.any? { |a| a[:kind] == "source.organizeImports" }.should be_false
  end
end
