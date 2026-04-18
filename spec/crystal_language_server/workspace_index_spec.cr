require "../spec_helper"
require "file_utils"

include CrystalLanguageServer

private def with_workspace_dir(&)
  dir = File.tempname("ws-index-spec")
  Dir.mkdir_p(dir)
  WorkspaceIndex.invalidate_all
  begin
    yield dir
  ensure
    WorkspaceIndex.invalidate_all
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

private def wait_for_index_warm(timeout : Time::Span = 5.seconds)
  deadline = CrystalLanguageServer.monotonic_now + timeout
  until WorkspaceIndex.name_index_ready?
    raise "WorkspaceIndex warm pass timed out" if CrystalLanguageServer.monotonic_now > deadline
    Fiber.yield
    sleep 10.milliseconds
  end
end

describe CrystalLanguageServer::WorkspaceIndex do
  describe "persistent name index" do
    it "warms from disk and serves bare + qualified lookups in O(1)" do
      with_workspace_dir do |root|
        File.write(File.join(root, "a.cr"), "class Foo\nend\n")
        File.write(File.join(root, "b.cr"), "class Bar::Baz\n  def hello\n  end\nend\n")

        ws = Workspace.new(Options.new)
        ws.root_path = root
        wait_for_index_warm

        foo = WorkspaceIndex.find_defs(ws, "Foo")
        foo.map(&.file).should contain File.join(root, "a.cr")
        foo.size.should eq 1

        # Qualified name finds the exact symbol.
        qualified = WorkspaceIndex.find_defs(ws, "Bar::Baz")
        qualified.map(&.file).should contain File.join(root, "b.cr")

        # Bare suffix reaches the qualified symbol without a full scan.
        bare = WorkspaceIndex.find_defs(ws, "Baz")
        bare.map(&.file).should contain File.join(root, "b.cr")

        # Method inside a qualified type is indexed as well.
        hello = WorkspaceIndex.find_defs(ws, "hello")
        hello.size.should eq 1
        hello.first.file.should eq File.join(root, "b.cr")
      end
    end

    it "prefers in-memory buffer over the on-disk index when a doc is open" do
      with_workspace_dir do |root|
        path = File.join(root, "a.cr")
        File.write(path, "class Old\nend\n")

        ws = Workspace.new(Options.new)
        ws.root_path = root
        wait_for_index_warm

        # Simulate an edit: didChange should re-index from the buffer
        # so a renamed symbol is visible before the file is saved.
        uri = DocumentUri.from_path(path)
        doc = ws.documents.open(uri, "class Renamed\nend\n", 1, "crystal")
        WorkspaceIndex.reindex_file_from_document(path, doc)

        old = WorkspaceIndex.find_defs(ws, "Old")
        old.should be_empty

        renamed = WorkspaceIndex.find_defs(ws, "Renamed")
        renamed.size.should eq 1
        renamed.first.file.should eq path

        # didClose re-reads disk, so the original on-disk symbol returns.
        ws.documents.close(uri)
        WorkspaceIndex.reindex_file_from_disk(path)

        WorkspaceIndex.find_defs(ws, "Renamed").should be_empty
        WorkspaceIndex.find_defs(ws, "Old").size.should eq 1
      end
    end

    it "drops entries when a watched file is deleted" do
      with_workspace_dir do |root|
        path = File.join(root, "gone.cr")
        File.write(path, "class Gone\nend\n")

        ws = Workspace.new(Options.new)
        ws.root_path = root
        wait_for_index_warm

        WorkspaceIndex.find_defs(ws, "Gone").size.should eq 1

        File.delete(path)
        WorkspaceIndex.reindex_file_from_disk(path)

        WorkspaceIndex.find_defs(ws, "Gone").should be_empty
      end
    end

    it "returns same results cold and warm" do
      with_workspace_dir do |root|
        File.write(File.join(root, "a.cr"), "module Alpha\n  class Beta\n  end\nend\n")

        ws = Workspace.new(Options.new)
        ws.root_path = root
        wait_for_index_warm

        warm = WorkspaceIndex.find_defs(ws, "Beta").map(&.file)
        warm.should contain File.join(root, "a.cr")

        # Reset everything so the next find_defs goes through the
        # cold-fallback scan path.
        WorkspaceIndex.invalidate_all
        WorkspaceIndex.name_index_ready?.should be_false

        cold = WorkspaceIndex.find_defs(ws, "Beta").map(&.file)
        cold.should eq warm
      end
    end
  end
end
