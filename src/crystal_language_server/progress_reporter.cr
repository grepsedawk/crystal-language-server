module CrystalLanguageServer
  # LSP `$/progress` emitter. Holds a pre-created progress token and
  # writes `begin` / `report` / `end` notifications through the shared
  # Transport so long-running server work (workspace index warm-up,
  # bulk reindex) shows up as a progress bar in the editor instead of
  # silent CPU.
  #
  # Creation of the token itself is the caller's responsibility — this
  # class assumes a `window/workDoneProgress/create` has already been
  # sent for the token.
  class ProgressReporter
    getter token : String

    def initialize(@transport : Transport, @token : String, @title : String)
    end

    def begin(message : String? = nil, percentage : Int32? = nil) : Nil
      emit({kind: "begin", title: @title, message: message, percentage: percentage, cancellable: false})
    end

    def report(message : String? = nil, percentage : Int32? = nil) : Nil
      emit({kind: "report", message: message, percentage: percentage})
    end

    def end_(message : String? = nil) : Nil
      emit({kind: "end", message: message})
    end

    private def emit(value) : Nil
      @transport.write Protocol.notification("$/progress", {token: @token, value: value})
    rescue ex
      Log.debug(exception: ex) { "progress emit failed" }
    end
  end
end
