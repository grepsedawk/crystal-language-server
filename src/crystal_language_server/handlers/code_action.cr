module CrystalLanguageServer
  module Handlers
    # Quick fixes matched against diagnostic text. Kept deliberately
    # small — over-eager actions make the menu noisy.
    module CodeAction
      extend self

      UNDEFINED_CONSTANT = /undefined constant `?([A-Z][A-Za-z0-9_:]*)`?/
      UNDEFINED_METHOD   = /undefined (?:local variable or )?method [`']([a-z_][a-zA-Z0-9_!?=]*)[`']/

      KIND_QUICKFIX                = "quickfix"
      KIND_SOURCE_FIXALL           = "source.fixAll"
      KIND_SOURCE_ORGANIZE_IMPORTS = "source.organizeImports"

      alias Action = NamedTuple(
        title: String,
        kind: String,
        diagnostics: Array(JSON::Any),
        edit: NamedTuple(changes: Hash(String, Array(NamedTuple(range: LspRange, newText: String)))),
      )

      def handle(ws : Workspace, params : JSON::Any)
        uri = params["textDocument"]["uri"].as_s
        doc = ws.documents[uri]?
        return [] of Action unless doc

        diagnostics = params.dig?("context", "diagnostics").try(&.as_a?) || [] of JSON::Any
        only = params.dig?("context", "only").try(&.as_a?).try(&.map(&.as_s))
        actions = [] of Action

        unless only && !wants_kind?(only, KIND_QUICKFIX)
          diagnostics.each { |d| add_quickfixes_for(ws, doc, uri, d, actions) }
        end

        # Only recompile for source.fixAll when the client explicitly
        # asked for it — on a "what actions apply here?" cursor request
        # we'd otherwise run a full `crystal build` per keystroke.
        if only && wants_kind?(only, KIND_SOURCE_FIXALL)
          add_fix_all(ws, doc, uri, actions)
        end

        if only && wants_kind?(only, KIND_SOURCE_ORGANIZE_IMPORTS)
          add_organize_imports(doc, uri, actions)
        end

        actions
      end

      private def add_organize_imports(doc : Document, uri : String, actions : Array(Action)) : Nil
        edits = OrganizeImports.edits_for(doc)
        return if edits.empty?
        actions << {
          title:       "Organize imports",
          kind:        KIND_SOURCE_ORGANIZE_IMPORTS,
          diagnostics: [] of JSON::Any,
          edit:        {changes: {uri => edits}},
        }
      end

      # Match LSP rules: a client requesting `source` also wants
      # `source.fixAll`, and one requesting `quickfix` accepts any
      # subkind. Equivalent to rust-analyzer's kind-tree check.
      private def wants_kind?(only : Array(String), kind : String) : Bool
        only.any? { |k| k == kind || kind.starts_with?("#{k}.") }
      end

      # Collect every require-style quickfix that applies anywhere in
      # the doc and bundle them as a single source.fixAll action.
      # Editors run these on save when the user opts into "fix all on
      # save" — the rust-analyzer / gopls / typescript-language-server
      # all expose this.
      private alias RequireEdit = NamedTuple(range: LspRange, newText: String)
      private record RequireFix, spec : String, edit : RequireEdit

      private def add_fix_all(ws : Workspace, doc : Document, uri : String, actions : Array(Action)) : Nil
        path = DocumentUri.to_path(uri)
        errors = ws.compiler.build_diagnostics(path, doc.text)
        seen = Set(String).new
        edits = [] of RequireEdit
        errors.each do |err|
          fixes_for(ws, doc, err.message, seen).each { |fix| edits << fix.edit }
        end
        return if edits.empty?
        actions << {
          title:       "Add missing `require` statements",
          kind:        KIND_SOURCE_FIXALL,
          diagnostics: [] of JSON::Any,
          edit:        {changes: {uri => edits}},
        }
      end

      private def add_quickfixes_for(ws, doc, uri, diag, actions : Array(Action))
        message = diag["message"]?.try(&.as_s?)
        return unless message
        fixes_for(ws, doc, message, Set(String).new).each do |fix|
          actions << {
            title:       "require \"#{fix.spec}\"",
            kind:        KIND_QUICKFIX,
            diagnostics: [diag],
            edit:        {changes: {uri => [fix.edit]}},
          }
        end
      end

      # Walk matching workspace definitions for the identifier named in
      # `message` and return a `RequireFix` for each that isn't already
      # covered by `seen_requires`. Empty if the message isn't one of
      # our kinds or the symbol is unknown.
      private def fixes_for(ws : Workspace, doc : Document, message : String,
                            seen_requires : Set(String)) : Array(RequireFix)
        fixes = [] of RequireFix
        matched = match_missing_symbol(message)
        return fixes if matched.nil?
        name, constant = matched
        base = constant ? name.split("::").first : name

        WorkspaceIndex.find_defs(ws, base).each do |site|
          next if site.file.empty?
          next unless kind_matches?(site, constant)
          spec = require_spec_for(doc, ws, site.file)
          next unless spec
          next unless seen_requires.add?(spec)
          fixes << RequireFix.new(spec, insert_require_edit(doc, doc.uri, spec))
        end
        fixes
      end

      # Returns `{symbol, is_constant}` if the message is a kind we can
      # auto-require for, nil otherwise. Keeping this in one place means
      # per-diagnostic quickfixes and fix-all walk the same regex set.
      private def match_missing_symbol(message : String) : {String, Bool}?
        if m = UNDEFINED_CONSTANT.match(message)
          {m[1], true}
        elsif m = UNDEFINED_METHOD.match(message)
          {m[1], false}
        end
      end

      private def kind_matches?(site : WorkspaceIndex::DefSite, constant : Bool) : Bool
        case site.kind
        when Protocol::SymbolKind::CLASS, Protocol::SymbolKind::STRUCT,
             Protocol::SymbolKind::MODULE, Protocol::SymbolKind::ENUM
          constant
        when Protocol::SymbolKind::METHOD, Protocol::SymbolKind::FUNCTION
          !constant
        else
          true
        end
      end

      # Compute the string to put inside `require "..."`. Relative when
      # the target lives inside the same shard source tree; shard name
      # when it's under a sibling's lib/<shard>/src/ directory.
      private def require_spec_for(doc : Document, ws : Workspace, target_file : String) : String?
        current_path = DocumentUri.to_path(doc.uri)
        root = ws.root_path

        # Shard-local dependency: lib/<shard>/src/<...>.
        if root && target_file.starts_with?(File.join(root, "lib", ""))
          tail = target_file.sub(File.join(root, "lib") + "/", "")
          parts = tail.split("/")
          return nil if parts.size < 3 || parts[1] != "src"
          shard = parts[0]
          rest = parts[2..].join("/")
          rest = rest.sub(/\.cr$/, "")
          return shard if rest == shard
          return "#{shard}/#{rest}"
        end

        # Same shard — make relative to the current file.
        relative = Path[target_file].relative_to(Path[File.dirname(current_path)])
        relative_str = relative.to_s.sub(/\.cr$/, "")
        relative_str = "./#{relative_str}" unless relative_str.starts_with?(".")
        relative_str
      end

      # Insert the new `require` at the end of the leading require
      # block so it joins the existing cluster. `OrganizeImports` owns
      # the definition of "leading require block" — asking it keeps
      # the two handlers in agreement on the boundary.
      private def insert_require_edit(doc : Document, uri : String, spec : String) : NamedTuple(range: LspRange, newText: String)
        insert_line = OrganizeImports.leading_require_line_count(doc)
        pos = LspPosition.new(insert_line, 0)
        {
          range:   LspRange.new(pos, pos),
          newText: "require \"#{spec}\"\n",
        }
      end
    end
  end
end
