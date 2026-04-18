require "../spec_helper"

describe CrystalLanguageServer::Transport do
  it "writes Content-Length framed JSON" do
    input = IO::Memory.new
    output = IO::Memory.new
    t = CrystalLanguageServer::Transport.new(input, output)
    t.write({jsonrpc: "2.0", id: 1, result: nil})

    output.to_s.should start_with("Content-Length: ")
    output.to_s.should contain("\r\n\r\n")
    output.to_s.should contain(%q("jsonrpc":"2.0"))
  end

  it "reads a single framed message" do
    body = %q({"jsonrpc":"2.0","id":1,"method":"ping"})
    input = IO::Memory.new("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    t = CrystalLanguageServer::Transport.new(input, IO::Memory.new)
    msg = t.read.not_nil!
    msg["method"].as_s.should eq "ping"
    msg["id"].as_i.should eq 1
  end

  it "returns nil on clean EOF" do
    t = CrystalLanguageServer::Transport.new(IO::Memory.new, IO::Memory.new)
    t.read.should be_nil
  end

  it "ignores spurious headers but requires Content-Length" do
    body = %q({"x":1})
    input = IO::Memory.new("Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    t = CrystalLanguageServer::Transport.new(input, IO::Memory.new)
    msg = t.read.not_nil!
    msg["x"].as_i.should eq 1
  end
end
