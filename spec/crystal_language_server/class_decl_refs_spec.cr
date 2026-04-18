require "../spec_helper"
require "file_utils"

include CrystalLanguageServer

private def refs_params(uri : String, line : Int32, character : Int32) : JSON::Any
  JSON.parse(%({
    "textDocument": {"uri": #{uri.to_json}},
    "position": {"line": #{line}, "character": #{character}},
    "context": {"includeDeclaration": true}
  }))
end

describe "findReferences on type declarations" do
  it "returns usages when cursor is inside `class BotCoordinator`" do
    dir = File.tempname("class-refs")
    Dir.mkdir_p(dir)
    begin
      coord = File.join(dir, "coordinator.cr")
      ctx = File.join(dir, "context.cr")
      File.write(coord, "class BotCoordinator\nend\n")
      File.write(ctx, "require \"./coordinator\"\n\nclass Ctx\n  property coordinator : BotCoordinator?\nend\n")

      uri = DocumentUri.from_path(coord)
      ws = Workspace.new(Options.new)
      ws.root_path = dir
      ws.documents.open(uri, File.read(coord), 1, "crystal")

      # Wait for name index warm-up (find_references uses tokens_for which
      # reads via scan cache, independent of name_index, but we wait to
      # mirror a realistic state).
      deadline = CrystalLanguageServer.monotonic_now + 5.seconds
      until WorkspaceIndex.name_index_ready?
        raise "warm pass timed out" if CrystalLanguageServer.monotonic_now > deadline
        Fiber.yield
        sleep 10.milliseconds
      end

      # Cursor inside "BotCoordinator" on line 0.
      line0 = File.read(coord).lines[0]
      col = line0.index!("BotCoordinator") + 3
      result = Handlers::References.handle(ws, refs_params(uri, 0, col))
      result.should_not be_nil
      raise "unreachable" unless result
      locs = result.as(Array)
      locs.size.should be >= 2 # decl + usage in context.cr
    ensure
      WorkspaceIndex.invalidate_all
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  it "returns usages when cursor is inside `module Hive`" do
    dir = File.tempname("module-refs")
    Dir.mkdir_p(dir)
    begin
      decl = File.join(dir, "hive.cr")
      use = File.join(dir, "use.cr")
      File.write(decl, "module Hive\nend\n")
      File.write(use, "require \"./hive\"\n\nclass Wrapper\n  def initialize\n    Hive.banner\n  end\nend\n")

      uri = DocumentUri.from_path(decl)
      ws = Workspace.new(Options.new)
      ws.root_path = dir
      ws.documents.open(uri, File.read(decl), 1, "crystal")

      deadline = CrystalLanguageServer.monotonic_now + 5.seconds
      until WorkspaceIndex.name_index_ready?
        raise "warm pass timed out" if CrystalLanguageServer.monotonic_now > deadline
        Fiber.yield
        sleep 10.milliseconds
      end

      line0 = File.read(decl).lines[0]
      col = line0.index!("Hive") + 1
      result = Handlers::References.handle(ws, refs_params(uri, 0, col))
      result.should_not be_nil
      raise "unreachable" unless result
      locs = result.as(Array)
      locs.size.should be >= 2
    ensure
      WorkspaceIndex.invalidate_all
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end
end
