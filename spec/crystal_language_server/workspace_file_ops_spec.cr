require "../spec_helper"
require "file_utils"

private def fresh_workspace
  CrystalLanguageServer::WorkspaceIndex.invalidate_all
  CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
end

describe CrystalLanguageServer::Handlers::WorkspaceChanges do
  it "didCreateFiles indexes the new file immediately" do
    dir = File.tempname("cls-create")
    Dir.mkdir_p(dir)
    begin
      ws = fresh_workspace
      ws.root_path = dir
      path = File.join(dir, "created.cr")
      File.write(path, "class Freshly_Created_Kind\nend\n")

      uri = CrystalLanguageServer::DocumentUri.from_path(path)
      params = JSON.parse(%({"files":[{"uri":#{uri.to_json}}]}))
      CrystalLanguageServer::Handlers::WorkspaceChanges.did_create_files(ws, params)

      defs = CrystalLanguageServer::WorkspaceIndex.find_defs(ws, "Freshly_Created_Kind")
      defs.should_not be_empty
      defs.first.file.should eq path
    ensure
      FileUtils.rm_rf(dir)
      CrystalLanguageServer::WorkspaceIndex.invalidate_all
    end
  end

  it "didDeleteFiles removes the file from the name index" do
    dir = File.tempname("cls-delete")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "gone.cr")
      File.write(path, "class Perishable_Name\nend\n")

      ws = fresh_workspace
      ws.root_path = dir
      CrystalLanguageServer::WorkspaceIndex.reindex_file_from_disk(path)
      CrystalLanguageServer::WorkspaceIndex.find_defs(ws, "Perishable_Name").should_not be_empty

      File.delete(path)
      uri = CrystalLanguageServer::DocumentUri.from_path(path)
      params = JSON.parse(%({"files":[{"uri":#{uri.to_json}}]}))
      CrystalLanguageServer::Handlers::WorkspaceChanges.did_delete_files(ws, params)

      CrystalLanguageServer::WorkspaceIndex.find_defs(ws, "Perishable_Name").should be_empty
    ensure
      FileUtils.rm_rf(dir)
      CrystalLanguageServer::WorkspaceIndex.invalidate_all
    end
  end

  it "didRenameFiles swaps the file in the name index" do
    dir = File.tempname("cls-rename")
    Dir.mkdir_p(dir)
    begin
      old_path = File.join(dir, "old.cr")
      new_path = File.join(dir, "new.cr")
      File.write(old_path, "class Shape_Shifter\nend\n")

      ws = fresh_workspace
      ws.root_path = dir
      CrystalLanguageServer::WorkspaceIndex.reindex_file_from_disk(old_path)

      File.rename(old_path, new_path)
      old_uri = CrystalLanguageServer::DocumentUri.from_path(old_path)
      new_uri = CrystalLanguageServer::DocumentUri.from_path(new_path)
      params = JSON.parse(%({"files":[{"oldUri":#{old_uri.to_json},"newUri":#{new_uri.to_json}}]}))
      CrystalLanguageServer::Handlers::WorkspaceChanges.did_rename_files(ws, params)

      defs = CrystalLanguageServer::WorkspaceIndex.find_defs(ws, "Shape_Shifter")
      defs.size.should eq 1
      defs.first.file.should eq new_path
    ensure
      FileUtils.rm_rf(dir)
      CrystalLanguageServer::WorkspaceIndex.invalidate_all
    end
  end
end
