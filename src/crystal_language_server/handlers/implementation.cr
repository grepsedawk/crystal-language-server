module CrystalLanguageServer
  module Handlers
    # `textDocument/implementation` — find concrete implementations of
    # the symbol at the cursor. Split out from Definition because the
    # two answer different questions on abstract methods and base
    # classes: Definition jumps to the declaration, Implementation
    # enumerates the overrides/subtypes.
    #
    # Scanner-heuristic in the same spirit as references/rename: no
    # receiver-type narrowing, so unrelated classes that happen to
    # declare the same method name appear together. Still a clear
    # improvement over aliasing to Definition, which on an abstract
    # `def foo` would just return the abstract def itself.
    module Implementation
      extend self

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return nil unless doc

        line = params["position"]["line"].as_i
        character = params["position"]["character"].as_i
        byte_offset = doc.position_to_offset(line, character)
        word = Scanner.user_identifier_at(doc.text, byte_offset)
        return nil unless word && !word.empty?

        first = word[0]
        return nil if first == '@' || first == '$'

        if first.ascii_uppercase?
          subtype_locations(ws, doc, word)
        else
          method_locations(ws, doc, uri, line, character, word)
        end
      end

      # For a method name: every def site with that name in the workspace,
      # minus the def the cursor itself sits on (so an abstract `def foo`
      # doesn't return itself in its own implementation list).
      private def method_locations(ws, doc, uri, line, character, word)
        path = DocumentUri.to_path(uri)
        cr_line = line + 1
        cr_column = doc.column_byte_offset(line, character) + 1

        compiler_hits = from_compiler(ws, path, doc.text, cr_line, cr_column)
        return compiler_hits if compiler_hits && !compiler_hits.empty?

        sites = WorkspaceIndex.find_defs(ws, word, priority_doc: doc)
        cursor_def = Scanner.enclosing_callable(doc.symbols, line)
        cursor_is_on_def_name = cursor_def &&
                                cursor_def.name == word &&
                                cursor_def.name_token.line == line &&
                                character_in_token?(cursor_def.name_token, character)

        locations = sites.compact_map do |site|
          next nil unless site.kind == Protocol::SymbolKind::METHOD ||
                          site.kind == Protocol::SymbolKind::FUNCTION
          site_path = site.file.empty? ? path : site.file
          if cursor_is_on_def_name &&
             site_path == path &&
             site.line == cursor_def.not_nil!.name_token.line &&
             site.column == cursor_def.not_nil!.name_token.column
            next nil
          end
          location_for(site, uri, word.size)
        end

        locations.empty? ? nil : locations
      end

      # For a type name: scanner-walk every class/struct whose opener
      # declares `< Name` and return their positions. Module include is
      # not followed — same limitation as type hierarchy.
      private def subtype_locations(ws, doc, word)
        sites = TypeHierarchy.subs_for(ws, word)
        return nil if sites.empty?
        sites.compact_map do |site|
          next nil if site.file.empty?
          location_for(site, DocumentUri.from_path(site.file), word.size)
        end
      end

      private def character_in_token?(tok : Scanner::Token, character : Int32) : Bool
        character >= tok.column && character <= tok.column + tok.text.size
      end

      private def from_compiler(ws, path, source, line, column)
        json = ws.compiler.implementations(path, source, line, column)
        return nil unless json
        return nil unless json["status"]?.try(&.as_s?) == "ok"
        impls = json["implementations"]?.try(&.as_a?)
        return nil unless impls
        locations = impls.compact_map { |entry| compiler_location(entry) }
        locations.empty? ? nil : locations
      end

      private def compiler_location(entry : JSON::Any)
        node = entry
        while (expanded = node["expands"]?)
          node = expanded
        end
        file = node["filename"]?.try(&.as_s?)
        line = node["line"]?.try(&.as_i?)
        col = node["column"]?.try(&.as_i?)
        return nil unless file && line && col
        return nil if file.empty? || file == "<unknown>"
        start = LspPosition.new(line - 1, col - 1)
        {uri: DocumentUri.from_path(file), range: LspRange.new(start, start)}
      end

      private def location_for(site : WorkspaceIndex::DefSite, uri : String, width : Int32)
        file_uri = site.file.empty? ? uri : DocumentUri.from_path(site.file)
        {
          uri:   file_uri,
          range: LspRange.new(
            LspPosition.new(site.line, site.column),
            LspPosition.new(site.line, site.column + width),
          ),
        }
      end
    end
  end
end
