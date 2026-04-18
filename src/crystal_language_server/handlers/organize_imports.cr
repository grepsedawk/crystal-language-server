module CrystalLanguageServer
  module Handlers
    # Sort + dedupe the contiguous leading `require "..."` block. Shared
    # by the `source.organizeImports` code action and the
    # `textDocument/willSaveWaitUntil` handler so both paths format
    # identically.
    module OrganizeImports
      extend self

      # Top-level Crystal stdlib require names. A bare require whose
      # first slash-separated segment matches one of these is grouped
      # into the stdlib bucket; anything else bare falls into shards.
      # Curated to cover the common surface — additions here are safe
      # because an unknown stdlib name just sorts alongside shards.
      STDLIB_REQUIRES = Set(String).new(%w(
        atomic base64 benchmark big colorize compress crypto csv db debug
        digest ecr fiber file_utils html http ini io json levenshtein
        llvm log math mime mutex oauth oauth2 openssl option_parser
        path process random readline regex semantic_version set slice
        socket spec string_pool string_scanner system tempfile time uri
        uuid weak_ref xml yaml
      ))

      REQUIRE_LINE = /^\s*require\s+"([^"]+)"\s*$/

      alias RequireEdit = NamedTuple(range: LspRange, newText: String)

      # Return a single edit replacing the leading require block with
      # its sorted + deduped form, or `[]` when the block is already
      # clean (or absent).
      def edits_for(doc : Document) : Array(RequireEdit)
        specs = collect_leading_specs(doc)
        return [] of RequireEdit if specs.empty?

        organized = organize(specs)
        return [] of RequireEdit if organized == specs

        new_text = String.build do |io|
          organized.each { |spec| io << %(require ") << spec << %(") << '\n' }
        end

        range = LspRange.new(
          LspPosition.new(0, 0),
          LspPosition.new(specs.size, 0),
        )
        [{range: range, newText: new_text}]
      end

      # Number of leading `require "…"` lines at the top of the doc —
      # also the line on which a new require should be inserted so it
      # joins the block. Shared with `CodeAction` so the fix-all
      # inserter and the organizer agree on where "the block ends."
      def leading_require_line_count(doc : Document) : Int32
        collect_leading_specs(doc).size
      end

      # Walk from line 0 and stop at the first non-require line. The
      # block therefore always occupies lines `0...specs.size`.
      private def collect_leading_specs(doc : Document) : Array(String)
        specs = [] of String
        doc.line_count.times do |i|
          m = REQUIRE_LINE.match(doc.line(i))
          break unless m
          specs << m[1]
        end
        specs
      end

      private def organize(specs : Array(String)) : Array(String)
        stdlib = [] of String
        shard = [] of String
        relative = [] of String
        specs.uniq.each do |spec|
          if spec.starts_with?("./") || spec.starts_with?("../")
            relative << spec
          elsif STDLIB_REQUIRES.includes?(spec.split('/', 2).first)
            stdlib << spec
          else
            shard << spec
          end
        end
        stdlib.sort! + shard.sort! + relative.sort!
      end
    end
  end
end
