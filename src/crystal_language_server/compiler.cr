require "./compiler/provider"
require "./compiler/subprocess"
require "./compiler/embedded"

module CrystalLanguageServer
  # The compiler-facing surface of the LSP. Handlers call into a
  # `Compiler::Provider` rather than a concrete adapter, so we can swap
  # between `Subprocess` (fork a `crystal` CLI per request) and
  # `Embedded` (link the compiler in-process) without rippling through
  # the handler layer.
  #
  # Selection happens at workspace construction; see `Workspace.new`.
  module Compiler
    # Pick the default provider based on the `CRYSTAL_LANGUAGE_SERVER_MODE`
    # env var. Falls back to `Subprocess` so nothing breaks if the
    # embedded build isn't compiled in — users opt in explicitly.
    def self.default(options : Options) : Provider
      mode = (ENV["CRYSTAL_LANGUAGE_SERVER_MODE"]? || "subprocess").downcase
      case mode
      when "embedded"
        if Embedded.available?
          Log.info { "compiler mode: embedded (in-process)" }
          Embedded.new
        else
          Log.warn { "embedded mode requested but compiler not linked — falling back to subprocess" }
          Subprocess.new(options.crystal_bin)
        end
      else
        Log.info { "compiler mode: subprocess (crystal bin: #{options.crystal_bin})" }
        Subprocess.new(options.crystal_bin)
      end
    end
  end
end
