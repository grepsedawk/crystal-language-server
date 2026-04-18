require "../spec_helper"

describe CrystalLanguageServer::DocumentUri do
  it "converts file URIs to paths" do
    CrystalLanguageServer::DocumentUri.to_path("file:///tmp/foo.cr").should eq "/tmp/foo.cr"
  end

  it "percent-decodes spaces and special characters" do
    CrystalLanguageServer::DocumentUri.to_path("file:///tmp/a%20b.cr").should eq "/tmp/a b.cr"
  end

  it "round-trips a simple absolute path" do
    uri = CrystalLanguageServer::DocumentUri.from_path("/tmp/foo.cr")
    CrystalLanguageServer::DocumentUri.to_path(uri).should eq "/tmp/foo.cr"
  end

  it "round-trips paths with spaces" do
    uri = CrystalLanguageServer::DocumentUri.from_path("/tmp/a b.cr")
    CrystalLanguageServer::DocumentUri.to_path(uri).should eq "/tmp/a b.cr"
  end
end
