module CrystalLanguageServer
  module Compiler
    # In-process Crystal compiler adapter. When compiled with a
    # `CRYSTAL_SOURCE_PATH` env var pointing at a Crystal compiler
    # checkout, we pull in `Crystal::Compiler`, `ContextVisitor`, and
    # `ImplementationsVisitor` and run them directly — no fork, no
    # tempfiles, no process boundary.
    #
    # When that env var isn't set at build time, this adapter stubs
    # out to `available? == false` so `Compiler.default` falls back to
    # `Subprocess`. That lets anyone `shards build` the server
    # without the compiler source handy; only release builds with
    # real performance expectations need the embedded path.
    #
    # Trade-offs documented in the module doc comment at
    # crystal_language_server/compiler.cr.
    class Embedded < Provider
      {% if env("CRYSTAL_SOURCE_PATH") %}
        COMPILED_WITH_SOURCE = true
      {% else %}
        COMPILED_WITH_SOURCE = false
      {% end %}

      def self.available? : Bool
        COMPILED_WITH_SOURCE
      end

      def initialize
        unless self.class.available?
          raise "Compiler::Embedded was instantiated without CRYSTAL_SOURCE_PATH set at build time. This is a bug — Compiler.default should've picked Subprocess."
        end
      end

      # Implementations are filled in by `embedded_impl.cr` when the
      # compiler source is available. See that file for the real
      # bodies.
      {% if env("CRYSTAL_SOURCE_PATH") %}
        # bodies provided by compiler/embedded_impl.cr
      {% else %}
        protected def context_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
          raise NotImplementedError.new("embedded compiler not linked")
        end

        protected def implementations_impl(file_path : String, source : String, line : Int32, column : Int32, cancel_token : CancelToken? = nil) : JSON::Any?
          raise NotImplementedError.new("embedded compiler not linked")
        end

        def format(source : String) : String?
          raise NotImplementedError.new("embedded compiler not linked")
        end

        protected def build_diagnostics_impl(file_path : String, source : String, cancel_token : CancelToken?) : Array(BuildError)
          raise NotImplementedError.new("embedded compiler not linked")
        end
      {% end %}
    end
  end
end

{% if env("CRYSTAL_SOURCE_PATH") %}
  require "./embedded_impl"
{% end %}
