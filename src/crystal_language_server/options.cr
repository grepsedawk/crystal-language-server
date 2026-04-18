module CrystalLanguageServer
  # When to run `crystal build` diagnostics. Running on every
  # didChange (with a short debounce) means typing pauses trigger a
  # full compile — on a real project that's a compiler process every
  # second or two, which pegs CPU and makes the editor feel laggy.
  # The default is now `on_save` to match Rust Analyzer / clangd /
  # gopls behavior out of the box.
  enum DiagnosticsTrigger
    OnChange
    OnSave
    Never
  end

  # Which LSP event caused a scheduled diagnostics run. Separate from
  # DiagnosticsTrigger (the user's configured policy).
  enum DiagnosticsEvent
    Open
    Change
    Save
  end

  # What the server should compute during
  # `textDocument/willSaveWaitUntil`. The handler blocks the editor's
  # save, so each action here must be quick and syntactic — no compiler
  # roundtrip.
  enum WillSaveActions
    None
    OrganizeImports
  end

  struct Options
    property log_path : String?
    property log_level : ::Log::Severity
    property crystal_bin : String
    property diagnostics_trigger : DiagnosticsTrigger
    property diagnostics_debounce : Float64
    property will_save_actions : WillSaveActions

    def initialize(
      @log_path = ENV["CRYSTAL_LANGUAGE_SERVER_LOG"]?,
      @log_level = Options.parse_level(ENV["CRYSTAL_LANGUAGE_SERVER_LOG_LEVEL"]? || "info"),
      @crystal_bin = ENV["CRYSTAL_LANGUAGE_SERVER_CRYSTAL"]? || "crystal",
      @diagnostics_trigger = Options.parse_trigger(ENV["CRYSTAL_LANGUAGE_SERVER_DIAGNOSTICS"]? || "on_save"),
      @diagnostics_debounce = (ENV["CRYSTAL_LANGUAGE_SERVER_DIAGNOSTICS_DEBOUNCE"]?.try(&.to_f?) || 0.4),
      @will_save_actions = Options.parse_will_save_actions(ENV["CRYSTAL_LANGUAGE_SERVER_WILL_SAVE_ACTIONS"]? || "none"),
    )
    end

    def self.parse(argv : Array(String)) : Options
      opts = Options.new
      i = 0
      while i < argv.size
        case argv[i]
        when "--stdio"
          # default, accepted for editor compatibility
        when "--log"
          opts.log_path = argv[i += 1]?
        when "--log-level"
          opts.log_level = parse_level(argv[i += 1]? || "info")
        when "--crystal"
          opts.crystal_bin = argv[i += 1]? || "crystal"
        when "--diagnostics"
          opts.diagnostics_trigger = parse_trigger(argv[i += 1]? || "on_save")
        when "--will-save-actions"
          opts.will_save_actions = parse_will_save_actions(argv[i += 1]? || "none")
        end
        i += 1
      end
      opts
    end

    def self.parse_trigger(s : String) : DiagnosticsTrigger
      case s.downcase
      when "on_change", "change", "onchange" then DiagnosticsTrigger::OnChange
      when "never", "off", "disabled"        then DiagnosticsTrigger::Never
      else                                        DiagnosticsTrigger::OnSave
      end
    end

    def self.parse_will_save_actions(s : String) : WillSaveActions
      case s.downcase
      when "organize_imports", "organizeimports" then WillSaveActions::OrganizeImports
      else                                            WillSaveActions::None
      end
    end

    def self.parse_level(s : String) : ::Log::Severity
      case s.downcase
      when "trace" then ::Log::Severity::Trace
      when "debug" then ::Log::Severity::Debug
      when "info"  then ::Log::Severity::Info
      when "warn"  then ::Log::Severity::Warn
      when "error" then ::Log::Severity::Error
      else              ::Log::Severity::Info
      end
    end
  end
end
