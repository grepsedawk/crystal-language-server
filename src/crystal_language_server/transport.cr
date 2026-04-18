module CrystalLanguageServer
  # Minimal LSP transport. The protocol framing is Content-Length-prefixed
  # JSON payloads separated by `\r\n\r\n`. We intentionally do not depend
  # on HTTP::Headers — LSP allows only `Content-Length` and an optional
  # `Content-Type`, and nothing else, so hand-parsing is simpler.
  class Transport
    class ParseError < Exception; end

    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
      @write_mutex = Mutex.new
      # We flush after every write in `write`, so no explicit sync toggle
      # is required — this keeps us compatible with any IO subclass.
    end

    # Read one JSON payload. Returns nil on clean EOF.
    def read : JSON::Any?
      headers = read_headers
      return nil if headers.nil?

      length = headers["content-length"]?.try &.to_i
      raise ParseError.new("missing Content-Length") unless length

      body = Bytes.new(length)
      @input.read_fully(body)
      JSON.parse(String.new(body))
    end

    # Write a JSON payload with the required framing. Thread-safe so
    # async-dispatched handlers can reply without interleaving.
    def write(message) : Nil
      body = message.is_a?(String) ? message : message.to_json
      bytes = body.to_slice
      @write_mutex.synchronize do
        @output << "Content-Length: " << bytes.size << "\r\n\r\n"
        @output.write(bytes)
        @output.flush
      end
    end

    private def read_headers : Hash(String, String)?
      headers = {} of String => String
      loop do
        line = @input.gets("\r\n", chomp: true)
        return nil if line.nil?
        break if line.empty?

        colon = line.index(':')
        raise ParseError.new("malformed header: #{line.inspect}") unless colon
        name = line[0...colon].strip.downcase
        value = line[(colon + 1)..].strip
        headers[name] = value
      end
      headers
    end
  end
end
