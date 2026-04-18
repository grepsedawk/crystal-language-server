module CrystalLanguageServer
  # JSON-RPC & LSP wire types. We intentionally don't model the whole
  # spec: only the parts this server sends or receives. The rest is read
  # as raw `JSON::Any` and handled by the relevant handler.
  module Protocol
    # --- JSON-RPC error codes (subset) --------------------------------

    module ErrorCodes
      PARSE_ERROR      = -32700
      INVALID_REQUEST  = -32600
      METHOD_NOT_FOUND = -32601
      INVALID_PARAMS   = -32602
      INTERNAL_ERROR   = -32603

      REQUEST_CANCELLED      = -32800
      SERVER_NOT_INITIALIZED = -32002
      UNKNOWN_ERROR_CODE     = -32001
    end

    # --- LSP enums ----------------------------------------------------

    module SymbolKind
      FILE           =  1
      MODULE         =  2
      NAMESPACE      =  3
      PACKAGE        =  4
      CLASS          =  5
      METHOD         =  6
      PROPERTY       =  7
      FIELD          =  8
      CONSTRUCTOR    =  9
      ENUM           = 10
      INTERFACE      = 11
      FUNCTION       = 12
      VARIABLE       = 13
      CONSTANT       = 14
      STRING         = 15
      NUMBER         = 16
      BOOLEAN        = 17
      ARRAY          = 18
      OBJECT         = 19
      KEY            = 20
      NULL           = 21
      ENUM_MEMBER    = 22
      STRUCT         = 23
      EVENT          = 24
      OPERATOR       = 25
      TYPE_PARAMETER = 26
    end

    module CompletionItemKind
      TEXT           =  1
      METHOD         =  2
      FUNCTION       =  3
      CONSTRUCTOR    =  4
      FIELD          =  5
      VARIABLE       =  6
      CLASS          =  7
      INTERFACE      =  8
      MODULE         =  9
      PROPERTY       = 10
      UNIT           = 11
      VALUE          = 12
      ENUM           = 13
      KEYWORD        = 14
      SNIPPET        = 15
      COLOR          = 16
      FILE           = 17
      REFERENCE      = 18
      FOLDER         = 19
      ENUM_MEMBER    = 20
      CONSTANT       = 21
      STRUCT         = 22
      EVENT          = 23
      OPERATOR       = 24
      TYPE_PARAMETER = 25
    end

    module DiagnosticSeverity
      ERROR       = 1
      WARNING     = 2
      INFORMATION = 3
      HINT        = 4
    end

    # LSP `MessageType` shared by `window/showMessage`,
    # `window/logMessage`, and `window/showMessageRequest`. Numbered
    # per the spec so we can pass the integer straight to the wire.
    module MessageType
      ERROR   = 1
      WARNING = 2
      INFO    = 3
      LOG     = 4
    end

    # LSP DiagnosticTag. `Unnecessary` lets editors dim the range (used
    # for unused locals / imports). `Deprecated` lets them strike it
    # through.
    module DiagnosticTag
      UNNECESSARY = 1
      DEPRECATED  = 2
    end

    module TextDocumentSyncKind
      NONE        = 0
      FULL        = 1
      INCREMENTAL = 2
    end

    # --- Response helpers --------------------------------------------

    def self.response(id, result)
      {jsonrpc: "2.0", id: id, result: result}
    end

    def self.error(id, code : Int32, message : String, data = nil)
      err = {code: code, message: message}
      {jsonrpc: "2.0", id: id, error: data ? err.merge({data: data}) : err}
    end

    def self.notification(method : String, params)
      {jsonrpc: "2.0", method: method, params: params}
    end

    def self.request(id, method : String, params)
      {jsonrpc: "2.0", id: id, method: method, params: params}
    end

    # --- Diagnostic ---------------------------------------------------

    struct Diagnostic
      include JSON::Serializable

      getter range : LspRange
      getter severity : Int32
      getter source : String
      getter message : String

      @[JSON::Field(ignore_serialize: tags.nil?)]
      getter tags : Array(Int32)?

      def initialize(@range, @severity, @message, @source = "crystal", @tags = nil)
      end
    end
  end
end
