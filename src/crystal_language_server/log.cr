module CrystalLanguageServer
  Log = ::Log.for("crystal-language-server")

  # Source pattern bound by both the stderr backend and the
  # `LogForwarder` — match every nested source under
  # `crystal-language-server` (`Log.for("...sub")`) so handlers can
  # opt into their own subloggers without losing forwarding.
  LOG_SOURCE_PATTERN = "crystal-language-server.*"

  def self.configure_logging(opts : Options)
    backend = if path = opts.log_path
                ::Log::IOBackend.new(File.open(path, "a"))
              else
                ::Log::IOBackend.new(STDERR)
              end
    ::Log.setup do |c|
      c.bind LOG_SOURCE_PATTERN, opts.log_level, backend
    end
  end

  # Forwards `Log` entries to the LSP client as `window/logMessage`
  # notifications. Installed once `initialize` has arrived so we
  # don't blast messages at a transport before the client is ready
  # to consume them. Additive: the existing stderr/file backend
  # keeps receiving the same entries.
  class LogForwarder < ::Log::Backend
    def initialize(@server : Server)
      super(::Log::DispatchMode::Sync)
    end

    def write(entry : ::Log::Entry) : Nil
      type = case entry.severity
             when .warn?           then Protocol::MessageType::WARNING
             when .error?, .fatal? then Protocol::MessageType::ERROR
             else                       Protocol::MessageType::INFO
             end
      @server.send_log_message(type, entry.message)
    rescue
      # Never let a broken transport recurse back into the logger.
    end
  end
end
