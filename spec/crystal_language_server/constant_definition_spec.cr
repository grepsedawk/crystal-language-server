require "../spec_helper"

# Regression: goto-definition on a top-level constant — even in the
# same file — used to return "No locations found" because the scanner
# didn't promote `NAME = expr` assignments to `SymbolNode`s. Exercises
# both the scanner surface and the Definition handler.

describe "top-level constants" do
  it "Scanner.document_symbols surfaces constant assignments" do
    source = <<-CR
      LAVA_ENTRANCE = Vec3i.new(1342, 21, 4990)
      LAVA_AREA     = NavArea.new
      CR

    roots = CrystalLanguageServer::Scanner.document_symbols(source)
    names = roots.map(&.name)
    names.should contain("LAVA_ENTRANCE")
    names.should contain("LAVA_AREA")

    entrance = roots.find { |n| n.name == "LAVA_ENTRANCE" }.not_nil!
    entrance.kind.should eq CrystalLanguageServer::Protocol::SymbolKind::CONSTANT
  end

  it "does not false-positive on a usage like `foo(FOO)`" do
    source = "x = foo(LAVA_ENTRANCE)\n"
    roots = CrystalLanguageServer::Scanner.document_symbols(source)
    roots.map(&.name).should_not contain("LAVA_ENTRANCE")
  end

  it "distinguishes `==` from a single `=` assignment" do
    source = "FOO == 1\n"
    roots = CrystalLanguageServer::Scanner.document_symbols(source)
    roots.map(&.name).should_not contain("FOO")
  end

  it "Definition handler resolves a same-file constant reference" do
    uri = "file:///constant-def.cr"
    source = <<-CR
      LAVA_ENTRANCE = Vec3i.new(1342, 21, 4990)

      LAVA_AREA = NavArea.new(
        name: "lava",
        nodes: [
          LAVA_ENTRANCE,
        ],
      )
      CR

    ws = ws_with_doc(uri, source)
    # Bootstrap the workspace name index off the open document so
    # Definition's workspace-fallback has something to look up.
    CrystalLanguageServer::WorkspaceIndex.invalidate_all
    CrystalLanguageServer::WorkspaceIndex.reindex_file_from_document(
      CrystalLanguageServer::DocumentUri.to_path(uri),
      ws.documents[uri],
    )

    # Cursor on the `LAVA_ENTRANCE` usage (line 5, character 10 — inside the token).
    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "position": {"line": 5, "character": 10}
    }))
    result = CrystalLanguageServer::Handlers::Definition.handle(ws, params)
    result.should_not be_nil
    raise "unreachable" unless result

    locs = result.as(Array)
    locs.should_not be_empty
    locs.first[:uri].should eq uri
    locs.first[:range].start.line.should eq 0 # definition is on line 0


  ensure
    CrystalLanguageServer::WorkspaceIndex.invalidate_all
  end
end
