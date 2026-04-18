require "../spec_helper"

# Keep the dispatcher from actually spawning a `crystal` subprocess
# during specs. `/bin/true` exits immediately with status 0 on every
# POSIX system — the spawned fiber runs to completion without
# producing output or errors.
private def safe_ws
  opts = CrystalLanguageServer::Options.new(crystal_bin: "/bin/true")
  CrystalLanguageServer::Workspace.new(opts)
end

describe CrystalLanguageServer::Handlers::WorkspaceChanges do
  describe "workspace/executeCommand" do
    it "returns nil for the runSpec command and accepts its arguments" do
      params = JSON.parse(%({
        "command": "crystal.runSpec",
        "arguments": ["file:///tmp/sample_spec.cr", 7, "adds two numbers"]
      }))
      result = CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(safe_ws, params)
      result.should be_nil
    end

    it "returns nil for runFile and formatFile" do
      ws = safe_ws
      run_params = JSON.parse(%({
        "command": "crystal.runFile",
        "arguments": ["file:///tmp/main.cr"]
      }))
      fmt_params = JSON.parse(%({
        "command": "crystal.formatFile",
        "arguments": ["file:///tmp/main.cr"]
      }))
      CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(ws, run_params).should be_nil
      CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(ws, fmt_params).should be_nil
    end

    it "rejects unknown commands cleanly (no exception)" do
      params = JSON.parse(%({"command": "crystal.pillage", "arguments": []}))
      result = CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(safe_ws, params)
      result.should be_nil
    end

    it "tolerates a missing command field" do
      params = JSON.parse(%({}))
      result = CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(safe_ws, params)
      result.should be_nil
    end

    it "tolerates runSpec with missing/malformed arguments" do
      ws = safe_ws
      # Missing name (arg 2)
      partial = JSON.parse(%({"command":"crystal.runSpec","arguments":["file:///tmp/x_spec.cr", 1]}))
      CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(ws, partial).should be_nil
      # Arguments of the wrong type
      garbage = JSON.parse(%({"command":"crystal.runSpec","arguments":[42, "nope", null]}))
      CrystalLanguageServer::Handlers::WorkspaceChanges.execute_command(ws, garbage).should be_nil
    end
  end

  it "advertises the three commands from executeCommandProvider" do
    CrystalLanguageServer::Handlers::WorkspaceChanges::COMMANDS.should eq [
      "crystal.runSpec", "crystal.runFile", "crystal.formatFile",
    ]
  end
end
