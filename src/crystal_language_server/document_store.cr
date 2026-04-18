module CrystalLanguageServer
  # Thread-safe map from URI to open Document. The LSP spec says content
  # for an open document always comes from the client, never from disk,
  # so this store is the sole source of truth while a document is open.
  class DocumentStore
    def initialize
      @mutex = Mutex.new
      @docs = {} of String => Document
    end

    def open(uri : String, text : String, version : Int32, language_id : String) : Document
      @mutex.synchronize do
        doc = Document.new(uri, text, version, language_id)
        @docs[uri] = doc
        doc
      end
    end

    def close(uri : String) : Nil
      @mutex.synchronize { @docs.delete(uri) }
    end

    def []?(uri : String) : Document?
      @mutex.synchronize { @docs[uri]? }
    end

    def [](uri : String) : Document
      self[uri]? || raise "no open document for #{uri}"
    end

    def each(& : Document ->) : Nil
      @mutex.synchronize { @docs.each_value { |d| yield d } }
    end

    def with_document(uri : String, & : Document ->) : Nil
      @mutex.synchronize do
        if doc = @docs[uri]?
          yield doc
        end
      end
    end
  end
end
