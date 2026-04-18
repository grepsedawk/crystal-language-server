require "../spec_helper"
require "file_utils"

private def crystal_available? : Bool
  Process.run("crystal", ["--version"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe CrystalLanguageServer::Handlers::CodeAction do
  it "returns a source.fixAll action covering all missing requires" do
    next if !crystal_available?

    dir = File.tempname("cls-fixall")
    Dir.mkdir_p(dir)
    begin
      shard = File.join(dir, "lib", "demo", "src")
      Dir.mkdir_p(shard)
      File.write(File.join(shard, "demo.cr"), "class DemoLib; end\n")

      entry = File.join(dir, "main.cr")
      source = "DemoLib.new\n"
      File.write(entry, source)

      CrystalLanguageServer::WorkspaceIndex.invalidate_all
      ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
      ws.root_path = dir
      uri = CrystalLanguageServer::DocumentUri.from_path(entry)
      ws.documents.open(uri, source, 1, "crystal")
      CrystalLanguageServer::WorkspaceIndex.reindex_file_from_disk(File.join(shard, "demo.cr"))

      params = JSON.parse(%({
        "textDocument": {"uri": #{uri.to_json}},
        "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":0}},
        "context": {"diagnostics": [], "only": ["source.fixAll"]}
      }))
      actions = CrystalLanguageServer::Handlers::CodeAction.handle(ws, params)

      fix_all = actions.find { |a| a[:kind] == "source.fixAll" }
      fix_all.should_not be_nil
      raise "unreachable" unless fix_all
      inserted = fix_all[:edit][:changes][uri].first[:newText]
      inserted.should contain(%(require "demo))
    ensure
      FileUtils.rm_rf(dir)
      CrystalLanguageServer::WorkspaceIndex.invalidate_all
    end
  end
end
