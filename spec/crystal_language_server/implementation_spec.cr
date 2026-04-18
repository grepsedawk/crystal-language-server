require "../spec_helper"

include CrystalLanguageServer

private def impl_params(uri : String, line : Int32, character : Int32) : JSON::Any
  JSON.parse(%({
    "textDocument": {"uri": #{uri.to_json}},
    "position": {"line": #{line}, "character": #{character}}
  }))
end

describe CrystalLanguageServer::Handlers::Implementation do
  it "returns concrete overrides for an abstract method, excluding the abstract def itself" do
    uri = "file:///impl-abstract.cr"
    source = <<-CR
      abstract class Base
        abstract def perform
      end

      class One < Base
        def perform
        end
      end

      class Two < Base
        def perform
        end
      end
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    # Cursor on the `perform` in `abstract def perform` (line 1, column 15).
    result = Handlers::Implementation.handle(ws, impl_params(uri, 1, 15))
    result.should_not be_nil
    raise "unreachable" unless result

    locs = result.as(Array)
    locs.size.should eq 2
    lines = locs.map(&.[:range].start.line).sort
    lines.should eq [5, 10]
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "returns subclasses when invoked on a type name" do
    uri = "file:///impl-type.cr"
    source = <<-CR
      class Shape
      end

      class Circle < Shape
      end

      class Square < Shape
      end
      CR

    ws = ws_with_doc(uri, source)
    WorkspaceIndex.invalidate_all
    WorkspaceIndex.reindex_file_from_document(DocumentUri.to_path(uri), ws.documents[uri])

    # Cursor on the `Shape` class declaration (line 0, character 6).
    result = Handlers::Implementation.handle(ws, impl_params(uri, 0, 6))
    result.should_not be_nil
    raise "unreachable" unless result

    locs = result.as(Array)
    locs.size.should eq 2
    locs.map(&.[:range].start.line).sort.should eq [3, 6]
  ensure
    WorkspaceIndex.invalidate_all
  end

  it "returns nil on a sigiled identifier" do
    uri = "file:///impl-ivar.cr"
    source = "class Foo\n  @count = 0\nend\n"
    ws = ws_with_doc(uri, source)
    Handlers::Implementation.handle(ws, impl_params(uri, 1, 3)).should be_nil
  end
end
