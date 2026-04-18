require "../spec_helper"

private def ws_with_doc_and_action(uri : String, source : String, action : CrystalLanguageServer::WillSaveActions) : CrystalLanguageServer::Workspace
  ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new(will_save_actions: action))
  ws.documents.open(uri, source, 1, "crystal")
  ws
end

private def params_for(uri : String) : JSON::Any
  JSON.parse(%({"textDocument": {"uri": #{uri.to_json}}}))
end

describe CrystalLanguageServer::Handlers::WillSave do
  it "returns no edits when will_save_actions is None" do
    uri = "file:///tmp/will_save_none.cr"
    ws = ws_with_doc_and_action(uri, "require \"yaml\"\nrequire \"json\"\n", :none)

    CrystalLanguageServer::Handlers::WillSave.wait_until(ws, params_for(uri)).should be_empty
  end

  it "returns organize-imports edits when configured and the block is dirty" do
    uri = "file:///tmp/will_save_sort.cr"
    ws = ws_with_doc_and_action(uri, "require \"yaml\"\nrequire \"json\"\n", :organize_imports)

    edits = CrystalLanguageServer::Handlers::WillSave.wait_until(ws, params_for(uri))
    edits.size.should eq 1
    edits.first[:newText].should eq "require \"json\"\nrequire \"yaml\"\n"
  end

  it "returns no edits when configured but the require block is already sorted" do
    uri = "file:///tmp/will_save_clean.cr"
    ws = ws_with_doc_and_action(uri, "require \"json\"\nrequire \"yaml\"\n", :organize_imports)

    CrystalLanguageServer::Handlers::WillSave.wait_until(ws, params_for(uri)).should be_empty
  end

  it "returns no edits (and does not raise) when the document is not open" do
    ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new(will_save_actions: :organize_imports))

    CrystalLanguageServer::Handlers::WillSave.wait_until(ws, params_for("file:///tmp/missing.cr")).should be_empty
  end
end
