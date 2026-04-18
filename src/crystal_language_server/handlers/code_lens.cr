module CrystalLanguageServer
  module Handlers
    # `textDocument/codeLens` — ephemeral annotations above code. We
    # surface:
    #
    #   * a "N references" lens over each top-level def/class (lazily
    #     resolved — the count only runs when the client is about to
    #     render), and
    #   * on `*_spec.cr` buffers, a "▶ Run" lens above every
    #     `it`/`describe`/`context "…"` call, wired to the
    #     `crystal.runSpec` command the client fires back through
    #     workspace/executeCommand.
    module CodeLens
      extend self

      alias ReferencesLens = NamedTuple(
        range: LspRange,
        data: NamedTuple(uri: String, name: String))

      alias TestLens = NamedTuple(
        range: LspRange,
        command: NamedTuple(
          title: String,
          command: String,
          arguments: Array(String | Int32)))

      alias Lens = ReferencesLens | TestLens

      RUN_LENS_TITLE = "\u25B6 Run"

      def handle(ws : Workspace, params : JSON::Any) : Array(Lens)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return [] of Lens unless doc

        lenses = [] of Lens
        doc.symbols.each { |root| collect_references(root, doc, uri, lenses) }
        if uri.ends_with?("_spec.cr")
          collect_test_lenses(doc, uri, lenses)
        end
        lenses
      end

      # `codeLens/resolve` — only reference lenses are unresolved; test
      # lenses ship complete from `handle` and pass straight through.
      def resolve(ws : Workspace, params : JSON::Any)
        data = params["data"]?
        return params unless data
        name = data["name"].as_s
        uri = data["uri"].as_s

        refs = WorkspaceIndex.find_references(ws, name)
        count = refs.size
        title = count == 1 ? "1 reference" : "#{count} references"

        {
          range:   params["range"],
          data:    data,
          command: {
            title:     title,
            command:   "crystalLanguageServer.showReferences",
            arguments: [uri, params["range"]],
          },
        }
      end

      private def collect_references(node : Scanner::SymbolNode, doc : Document, uri : String, acc : Array(Lens))
        if lens_kind?(node.kind) && !node.name.empty?
          name_range = LspRange.new(
            doc.offset_to_position(node.name_token.byte_start),
            doc.offset_to_position(node.name_token.byte_end),
          )
          acc << {range: name_range, data: {uri: uri, name: node.name}}
        end
        node.children.each { |c| collect_references(c, doc, uri, acc) }
      end

      private def collect_test_lenses(doc : Document, uri : String, acc : Array(Lens))
        Scanner.spec_examples(doc.tokens).each do |ex|
          verb_range = LspRange.new(
            doc.offset_to_position(ex.verb_token.byte_start),
            doc.offset_to_position(ex.verb_token.byte_end),
          )
          # Arguments flow back to us verbatim through
          # workspace/executeCommand. Line is 1-based so it matches
          # what editors display.
          acc << {
            range:   verb_range,
            command: {
              title:     RUN_LENS_TITLE,
              command:   WorkspaceChanges::RUN_SPEC_COMMAND,
              arguments: [uri, ex.verb_token.line + 1, ex.name] of String | Int32,
            },
          }
        end
      end

      private def lens_kind?(kind : Int32) : Bool
        case kind
        when Protocol::SymbolKind::CLASS, Protocol::SymbolKind::STRUCT,
             Protocol::SymbolKind::MODULE, Protocol::SymbolKind::ENUM,
             Protocol::SymbolKind::METHOD, Protocol::SymbolKind::FUNCTION
          true
        else
          false
        end
      end
    end
  end
end
