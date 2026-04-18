require "../spec_helper"

describe "Lifecycle outbound requests" do
  it "registers a **/*.cr file watcher on `initialized`" do
    output = IO::Memory.new
    transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
    server = CrystalLanguageServer::Server.new(CrystalLanguageServer::Options.new, transport)

    server.handle(JSON.parse({jsonrpc: "2.0", method: "initialized", params: {} of String => String}.to_json))

    messages = drain_transport(output)
    register = messages.find do |m|
      m["method"]?.try(&.as_s?) == "client/registerCapability"
    end
    register.should_not be_nil
    raise "unreachable" unless register

    regs = register["params"]["registrations"].as_a
    watched = regs.find { |r| r["method"].as_s == "workspace/didChangeWatchedFiles" }
    watched.should_not be_nil
    raise "unreachable" unless watched
    watched["registerOptions"]["watchers"].as_a.first["globPattern"].as_s.should eq "**/*.cr"
  end

  it "creates a progress token and sets up a reporter when the client supports work-done progress" do
    output = IO::Memory.new
    transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
    server = CrystalLanguageServer::Server.new(CrystalLanguageServer::Options.new, transport)

    params = JSON.parse({
      capabilities: {window: {workDoneProgress: true}},
    }.to_json)
    server.handle(JSON.parse({
      jsonrpc: "2.0",
      id:      1,
      method:  "initialize",
      params:  params,
    }.to_json))

    # Give the spawned request-handler fiber a tick to flush.
    sleep 10.milliseconds

    messages = drain_transport(output)
    create_req = messages.find do |m|
      m["method"]?.try(&.as_s?) == "window/workDoneProgress/create"
    end
    create_req.should_not be_nil
    server.workspace.progress_reporter.should_not be_nil
  end

  it "skips the progress reporter entirely when the client does not support work-done progress" do
    output = IO::Memory.new
    transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
    server = CrystalLanguageServer::Server.new(CrystalLanguageServer::Options.new, transport)

    params = JSON.parse({capabilities: {} of String => String}.to_json)
    server.handle(JSON.parse({
      jsonrpc: "2.0",
      id:      2,
      method:  "initialize",
      params:  params,
    }.to_json))

    sleep 10.milliseconds

    messages = drain_transport(output)
    messages.any? { |m| m["method"]?.try(&.as_s?) == "window/workDoneProgress/create" }.should be_false
    server.workspace.progress_reporter.should be_nil
  end
end
