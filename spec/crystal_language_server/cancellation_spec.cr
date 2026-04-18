require "../spec_helper"

# Stub compiler provider that blocks in `context` until released. The
# first call records its cancel_token so the spec can assert the server
# threaded one through; releasing the gate unblocks the handler.
private class BlockingProvider < CrystalLanguageServer::Compiler::Provider
  getter gate = Channel(Nil).new
  getter observed_token : CrystalLanguageServer::CancelToken? = nil

  def context(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CrystalLanguageServer::CancelToken? = nil) : JSON::Any?
    @observed_token = cancel_token
    # Block until either the spec releases us or the cancel token fires.
    # Mirrors what Subprocess.run_io does.
    cancel_channel = cancel_token.try(&.channel) || Channel(Nil).new
    select
    when @gate.receive?
      JSON.parse(%q({"status":"failed"}))
    when cancel_channel.receive?
      nil
    end
  end

  def implementations(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CrystalLanguageServer::CancelToken? = nil) : JSON::Any?
    nil
  end

  protected def context_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CrystalLanguageServer::CancelToken? = nil) : JSON::Any?
    nil
  end

  protected def implementations_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CrystalLanguageServer::CancelToken? = nil) : JSON::Any?
    nil
  end

  def format(source : String) : String?
    source
  end

  protected def build_diagnostics_impl(file_path : String, source : String, cancel_token : CrystalLanguageServer::CancelToken?) : Array(CrystalLanguageServer::Compiler::BuildError)
    [] of CrystalLanguageServer::Compiler::BuildError
  end
end

describe "CrystalLanguageServer::Server $/cancelRequest" do
  it "replies with -32800 when a request is cancelled in-flight" do
    output = IO::Memory.new
    transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
    server = CrystalLanguageServer::Server.new(CrystalLanguageServer::Options.new, transport)

    provider = BlockingProvider.new
    server.workspace.compiler = provider

    uri = "file:///tmp/cancel-spec.cr"
    server.workspace.documents.open(uri, "x = 1\n", 1, "crystal")

    # Dispatch a hover request — the BlockingProvider will park inside
    # `context` until we release the gate or cancel trips the token.
    server.handle(JSON.parse({
      jsonrpc: "2.0",
      id:      42,
      method:  "textDocument/hover",
      params:  {
        textDocument: {uri: uri},
        position:     {line: 0, character: 0},
      },
    }.to_json))

    # Spin briefly until the server fiber has started the hover and the
    # provider has seen the request. Cheap because the fiber is already
    # blocked in the select.
    deadline = CrystalLanguageServer.monotonic_now + 2.seconds
    while provider.observed_token.nil?
      Fiber.yield
      break if CrystalLanguageServer.monotonic_now > deadline
    end
    provider.observed_token.should_not be_nil

    # Send the cancel notification. The token trip should unblock the
    # BlockingProvider's select and the dispatch_request_async wrapper
    # should emit the -32800 error.
    server.handle(JSON.parse({
      jsonrpc: "2.0",
      method:  "$/cancelRequest",
      params:  {id: 42},
    }.to_json))

    deadline = CrystalLanguageServer.monotonic_now + 2.seconds
    while output.to_s.empty? && CrystalLanguageServer.monotonic_now < deadline
      Fiber.yield
    end

    raw = output.to_s
    raw.should contain("-32800")
    raw.should contain(%q("id":42))

    body = raw.split("\r\n\r\n", 2).last
    json = JSON.parse(body)
    json["error"]["code"].as_i.should eq(-32800)
    json["id"].as_i.should eq 42
  end

  it "responds normally when no cancel arrives" do
    output = IO::Memory.new
    transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
    server = CrystalLanguageServer::Server.new(CrystalLanguageServer::Options.new, transport)

    provider = BlockingProvider.new
    server.workspace.compiler = provider

    uri = "file:///tmp/cancel-ok-spec.cr"
    server.workspace.documents.open(uri, "x = 1\n", 1, "crystal")

    server.handle(JSON.parse({
      jsonrpc: "2.0",
      id:      "h1",
      method:  "textDocument/hover",
      params:  {
        textDocument: {uri: uri},
        position:     {line: 0, character: 0},
      },
    }.to_json))

    # Release the provider; the handler continues past the context
    # call, eventually returning nil (no hover info). We just want to
    # verify the response is *not* a cancel error.
    provider.gate.close

    deadline = CrystalLanguageServer.monotonic_now + 2.seconds
    while output.to_s.empty? && CrystalLanguageServer.monotonic_now < deadline
      Fiber.yield
    end

    raw = output.to_s
    raw.should_not contain("-32800")
    raw.should contain(%q("id":"h1"))
  end
end
