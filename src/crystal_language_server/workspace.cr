module CrystalLanguageServer
  # Session-wide state shared across handlers. Holds configuration from
  # `initialize` (root path, capabilities), the in-memory document
  # store, and the `Compiler::Provider` instance handlers use for all
  # semantic queries.
  #
  # The provider is selected from `CRYSTAL_LANGUAGE_SERVER_MODE` when
  # the workspace is constructed.
  class Workspace
    getter documents : DocumentStore
    # `property` instead of `getter` so specs can swap in a stub
    # provider. The hot path only reads this once at handler entry, so
    # the extra indirection is free.
    property compiler : Compiler::Provider
    getter options : Options
    getter root_path : String?
    property client_capabilities : JSON::Any?
    # Set by the Server when the client advertises
    # `window.workDoneProgress` support; the warm pass uses it to emit
    # `$/progress` so editors can show an indexing spinner.
    property progress_reporter : ProgressReporter?

    def initialize(@options : Options)
      @documents = DocumentStore.new
      @compiler = Compiler.default(@options)
    end

    # Setting the root path kicks off a background warm of the
    # workspace-wide name index so the first `find_defs` after startup
    # doesn't pay the full-scan cost.
    def root_path=(path : String?)
      @root_path = path
      WorkspaceIndex.warm_name_index_async(path, @progress_reporter) if path
    end
  end
end
