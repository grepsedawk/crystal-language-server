require "../spec_helper"
require "file_utils"

private def crystal_available? : Bool
  Process.run("crystal", ["--version"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe CrystalLanguageServer::Handlers::PullDiagnostics do
  it "returns an empty `full` report when the document is unknown" do
    ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
    params = JSON.parse(%({"textDocument":{"uri":"file:///does-not-exist.cr"}}))

    report = CrystalLanguageServer::Handlers::PullDiagnostics.handle(ws, params)
    report[:kind].should eq "full"
    report[:items].should be_empty
  end

  it "returns a `full` report containing the compiler errors for a broken buffer" do
    next if !crystal_available?

    dir = File.tempname("cls-pull-diag-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "broken.cr")
    source = "undefined_method_please\n"
    File.write(path, source)

    begin
      ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
      uri = CrystalLanguageServer::DocumentUri.from_path(path)
      ws.documents.open(uri, source, 1, "crystal")

      params = JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}}))
      report = CrystalLanguageServer::Handlers::PullDiagnostics.handle(ws, params)

      report[:kind].should eq "full"
      report[:items].size.should be >= 1
      report[:items].first.message.should contain("undefined")
    ensure
      FileUtils.rm_rf(dir) rescue nil
    end
  end

  it "is advertised in the lifecycle capabilities" do
    caps = CrystalLanguageServer::Handlers::Lifecycle.capabilities
    caps[:diagnosticProvider][:interFileDependencies].should be_false
    caps[:diagnosticProvider][:workspaceDiagnostics].should be_false
  end
end

describe "Compiler::Provider build_diagnostics caching" do
  it "serves the second call from cache when source is unchanged" do
    next if !crystal_available?

    dir = File.tempname("cls-pull-diag-cache-spec")
    Dir.mkdir_p(dir)
    path = File.join(dir, "broken.cr")
    source = "undefined_method_please\n"
    File.write(path, source)

    provider = CrystalLanguageServer::Compiler::Subprocess.new
    begin
      first = provider.build_diagnostics(path, source)

      # Make the on-disk file inconsistent. If the cache hit works, the
      # second call should still return the original errors instead of
      # re-running the compiler against the (now-empty) on-disk source.
      File.write(path, "")
      second = provider.build_diagnostics(path, source)

      first.size.should eq second.size
      first.first.message.should eq second.first.message
    ensure
      FileUtils.rm_rf(dir) rescue nil
    end
  end
end
