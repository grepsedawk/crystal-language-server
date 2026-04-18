require "uri"

module CrystalLanguageServer
  # LSP `DocumentUri` is a URI string — almost always `file://...`. This
  # module centralises the file <-> uri mapping, with percent-decoding for
  # spaces etc., so call sites can treat paths as plain strings.
  module DocumentUri
    extend self

    def to_path(uri : String) : String
      if uri.starts_with?("file://")
        rest = uri[7..]
        # file:///C:/foo on Windows has a leading slash we must strip
        {% if flag?(:win32) %}
          rest = rest[1..] if rest.size > 2 && rest[0] == '/' && rest[2] == ':'
        {% end %}
        ::URI.decode(rest)
      else
        uri
      end
    end

    def from_path(path : String) : String
      absolute = File.expand_path(path)
      encoded = absolute.gsub(/([^A-Za-z0-9\-._~\/:])/) { |c| "%%%02X" % c.bytes.first }
      {% if flag?(:win32) %}
        "file:///#{encoded.lchop('/')}"
      {% else %}
        "file://#{encoded}"
      {% end %}
    end
  end
end
