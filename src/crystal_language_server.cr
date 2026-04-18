require "json"
require "log"

require "./crystal_language_server/compat"
require "./crystal_language_server/options"
require "./crystal_language_server/log"
require "./crystal_language_server/uri"
require "./crystal_language_server/position"
require "./crystal_language_server/protocol"
require "./crystal_language_server/transport"
require "./crystal_language_server/progress_reporter"
require "./crystal_language_server/document"
require "./crystal_language_server/document_store"
require "./crystal_language_server/scanner"
require "./crystal_language_server/cancel_token"
require "./crystal_language_server/compiler"
require "./crystal_language_server/workspace"
require "./crystal_language_server/workspace_index"
require "./crystal_language_server/handlers"
require "./crystal_language_server/server"

module CrystalLanguageServer
  # Baked at compile time from shard.yml so `--version` and the
  # LSP `serverInfo` both stay in sync without a second source of
  # truth. Defined here (not in the CLI entrypoint) so specs that
  # instantiate `Server` directly can still link.
  VERSION = {{ `shards version "#{__DIR__}"`.stringify.chomp }}
end
