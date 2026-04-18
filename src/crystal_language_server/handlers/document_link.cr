module CrystalLanguageServer
  module Handlers
    # `textDocument/documentLink` — turns `require "..."` lines into
    # ctrl-click navigation to the required file. We resolve the three
    # common shapes Crystal code uses:
    #
    #   require "./relative"            -> relative to the current file
    #   require "../other"              -> ditto, upward
    #   require "some_shard/feature"    -> <root>/lib/some_shard/src/feature.cr
    #   require "some_shard"            -> <root>/lib/some_shard/src/some_shard.cr
    #
    # Stdlib requires (`require "json"`, etc.) are skipped — we could
    # resolve them by shelling out to `crystal env CRYSTAL_PATH` and
    # walking the stdlib tree, but it's noisy (every require would
    # jump into stdlib) and Crystal's `crystal tool implementations`
    # already handles per-symbol goto into stdlib.
    module DocumentLink
      extend self

      REQUIRE_LINE = /^\s*require\s+"([^"]+)"/

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return [] of Nil unless doc

        file_path = DocumentUri.to_path(uri)
        file_dir = File.dirname(file_path)
        shard_root = Compiler::EntrypointResolver.find_shard_root(file_path)

        results = [] of NamedTuple(range: LspRange, target: String)
        doc.each_line do |text, line_idx|
          match = REQUIRE_LINE.match(text)
          next unless match

          spec = match[1]
          target_path = resolve(spec, file_dir, shard_root)
          next unless target_path

          # Compute the range around the string contents (exclusive of quotes).
          # `match.pre_match_size` in Crystal Regex::MatchData isn't exposed, so
          # find the quote positions by scanning.
          open_quote = text.index('"')
          close_quote = text.rindex('"')
          next unless open_quote && close_quote && close_quote > open_quote

          range = LspRange.new(
            LspPosition.new(line_idx, open_quote + 1),
            LspPosition.new(line_idx, close_quote),
          )
          results << {range: range, target: DocumentUri.from_path(target_path)}
        end
        results
      end

      private def resolve(spec : String, file_dir : String, shard_root : String?) : String?
        # Relative requires: resolve against the current file's directory.
        if spec.starts_with?("./") || spec.starts_with?("../")
          return try_candidates(File.expand_path(spec, file_dir))
        end

        return nil unless shard_root

        # Shard-local requires: <root>/lib/<shard>/src/<rest>
        if slash = spec.index('/')
          shard = spec[0...slash]
          rest = spec[(slash + 1)..]
          base = File.join(shard_root, "lib", shard, "src", rest)
          return try_candidates(base)
        end

        # Bare name: <root>/lib/<name>/src/<name>.cr
        base = File.join(shard_root, "lib", spec, "src", spec)
        try_candidates(base)
      end

      private def try_candidates(base : String) : String?
        return base if regular_file?(base)
        with_ext = base.ends_with?(".cr") ? base : "#{base}.cr"
        return with_ext if regular_file?(with_ext)
        nil
      end

      private def regular_file?(path : String) : Bool
        File.info?(path).try(&.file?) == true
      end
    end
  end
end
