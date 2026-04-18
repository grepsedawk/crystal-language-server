require "../spec_helper"

describe "BuildError#to_diagnostic tags" do
  it "tags 'unused' messages with DiagnosticTag::UNNECESSARY" do
    err = CrystalLanguageServer::Compiler::BuildError.new(
      file: "/tmp/x.cr", line: 1, column: 1, size: 3,
      message: "warning: unused variable 'foo'",
    )
    diag = err.to_diagnostic("/tmp/x.cr")
    tags = diag.tags
    tags.should_not be_nil
    tags.not_nil!.should contain(CrystalLanguageServer::Protocol::DiagnosticTag::UNNECESSARY)
  end

  it "tags 'deprecated' messages with DiagnosticTag::DEPRECATED" do
    err = CrystalLanguageServer::Compiler::BuildError.new(
      file: "/tmp/x.cr", line: 2, column: 1, size: 3,
      message: "warning: Deprecated Foo.bar",
    )
    diag = err.to_diagnostic("/tmp/x.cr")
    diag.tags.not_nil!.should contain(CrystalLanguageServer::Protocol::DiagnosticTag::DEPRECATED)
  end

  it "leaves plain errors untagged" do
    err = CrystalLanguageServer::Compiler::BuildError.new(
      file: "/tmp/x.cr", line: 3, column: 1, size: 3,
      message: "undefined constant Foo",
    )
    err.to_diagnostic("/tmp/x.cr").tags.should be_nil
  end
end
