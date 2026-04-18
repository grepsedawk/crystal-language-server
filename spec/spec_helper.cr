require "spec"

# Set before the server is required so every `Options.new` picks it
# up. Keeps spec output readable: per-constructor `configure_logging`
# re-binds the global log source; without this it would re-enable
# INFO-level chatter that floods stderr during the run.
ENV["CRYSTAL_LANGUAGE_SERVER_LOG_LEVEL"] ||= "error"
# Route the stderr IOBackend at /dev/null so intentional error-path
# logs from handlers under test (e.g. executeCommand spawn failures)
# don't print stack traces on every run.
ENV["CRYSTAL_LANGUAGE_SERVER_LOG"] ||= "/dev/null"

require "../src/crystal_language_server"

# Additionally route the default backend to /dev/null — some tests
# that exercise error-path handlers intentionally trigger stack-trace
# logging; we want those captured in Log assertions, not on stderr.
::Log.setup(:error, ::Log::IOBackend.new(IO::Memory.new))

# Open a single-document workspace around `source`, ready to pass to
# any handler. Shared across specs that exercise handlers directly
# without the transport round-trip.
def ws_with_doc(uri : String, source : String, version : Int32 = 1) : CrystalLanguageServer::Workspace
  ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
  ws.documents.open(uri, source, version, "crystal")
  ws
end

# Decode the LSP framing on `output` and return each framed message
# as parsed JSON. Used by specs that drive Server through Transport
# and want to inspect the outgoing wire.
def drain_transport(output : IO::Memory) : Array(JSON::Any)
  raw = output.to_s
  messages = [] of JSON::Any
  until raw.empty?
    header_end = raw.index("\r\n\r\n")
    break unless header_end
    length = raw[0...header_end].match(/Content-Length: (\d+)/).not_nil![1].to_i
    body_start = header_end + 4
    messages << JSON.parse(raw[body_start, length])
    raw = raw[(body_start + length)..]
  end
  messages
end
