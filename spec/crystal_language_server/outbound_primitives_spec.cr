require "../spec_helper"

private def build_server
  output = IO::Memory.new
  transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
  server = CrystalLanguageServer::Server.new(CrystalLanguageServer::Options.new, transport)
  {server, output}
end

describe "Outbound primitives" do
  it "send_log_message writes a window/logMessage notification" do
    server, output = build_server
    server.send_log_message(CrystalLanguageServer::Protocol::MessageType::WARNING, "hello client")

    msgs = drain_transport(output)
    msgs.size.should eq 1
    msgs[0]["jsonrpc"].as_s.should eq "2.0"
    msgs[0]["method"].as_s.should eq "window/logMessage"
    msgs[0]["params"]["type"].as_i.should eq CrystalLanguageServer::Protocol::MessageType::WARNING
    msgs[0]["params"]["message"].as_s.should eq "hello client"
    msgs[0]["id"]?.should be_nil
  end

  it "send_show_document writes a window/showDocument REQUEST with an id" do
    server, output = build_server
    server.send_show_document("file:///tmp/foo.cr", external: false, take_focus: true)

    msgs = drain_transport(output)
    msgs.size.should eq 1
    msgs[0]["method"].as_s.should eq "window/showDocument"
    msgs[0]["id"]?.should_not be_nil
    msgs[0]["params"]["uri"].as_s.should eq "file:///tmp/foo.cr"
    msgs[0]["params"]["external"].as_bool.should be_false
    msgs[0]["params"]["takeFocus"].as_bool.should be_true
    msgs[0]["params"]["selection"]?.should be_nil
  end

  it "includes the selection range when send_show_document is given one" do
    server, output = build_server
    pos = CrystalLanguageServer::LspPosition.new(2, 0)
    range = CrystalLanguageServer::LspRange.new(pos, pos)
    server.send_show_document("file:///tmp/bar.cr", selection: range)

    msgs = drain_transport(output)
    sel = msgs[0]["params"]["selection"]
    sel["start"]["line"].as_i.should eq 2
    sel["end"]["line"].as_i.should eq 2
  end

  it "request_configuration writes a workspace/configuration request with the items array" do
    server, output = build_server
    items = [
      {scopeUri: nil, section: "crystal"},
      {scopeUri: "file:///x", section: nil},
    ] of CrystalLanguageServer::Server::ConfigurationItem
    server.request_configuration(items)

    msgs = drain_transport(output)
    msgs.size.should eq 1
    msgs[0]["method"].as_s.should eq "workspace/configuration"
    msgs[0]["id"]?.should_not be_nil
    items_json = msgs[0]["params"]["items"].as_a
    items_json.size.should eq 2
    items_json[0]["section"].as_s.should eq "crystal"
    items_json[1]["scopeUri"].as_s.should eq "file:///x"
  end

  it "attach_client_log_forwarding routes Log entries through window/logMessage" do
    server, output = build_server
    server.attach_client_log_forwarding

    CrystalLanguageServer::Log.warn { "client visible warning" }

    msgs = drain_transport(output)
    log_msg = msgs.find { |m| m["method"]?.try(&.as_s?) == "window/logMessage" }
    log_msg.should_not be_nil
    raise "unreachable" unless log_msg
    log_msg["params"]["type"].as_i.should eq CrystalLanguageServer::Protocol::MessageType::WARNING
    log_msg["params"]["message"].as_s.should eq "client visible warning"
  end
end
