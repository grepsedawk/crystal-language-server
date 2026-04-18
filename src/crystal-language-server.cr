require "./crystal_language_server"

# CLI entrypoint. The LSP server speaks JSON-RPC over stdio — it has
# essentially no flags; editors spawn the binary and talk to it directly.
module CrystalLanguageServer
  def self.run_cli(argv : Array(String))
    case argv.first?
    when "--version", "-v"
      puts "crystal-language-server #{VERSION}"
    when "--help", "-h"
      puts <<-HELP
        crystal-language-server — Language Server for Crystal

        Usage: crystal-language-server [--stdio]

        Speaks LSP over stdio. Flags are accepted for editor compatibility
        but stdio is the only supported transport.

          --stdio        (default) communicate via stdin/stdout
          --log PATH     write server logs to PATH (default: STDERR)
          --log-level L  trace|debug|info|warn|error (default: info)
          --version      print version
          --help         this message
        HELP
    else
      opts = Options.parse(argv)
      Server.new(opts).run
    end
  end
end

CrystalLanguageServer.run_cli(ARGV)
