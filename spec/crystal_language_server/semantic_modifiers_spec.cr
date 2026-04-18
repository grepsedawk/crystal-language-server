require "../spec_helper"

# `SemanticTokens#encode` is private, so we exercise it by calling
# `handle` on a document and decoding the flat int array back into
# per-token slices. The token format is
#   [deltaLine, deltaChar, length, typeIdx, modifierBitmask] * N.
private def tokens_for(source : String)
  uri = "file:///mod-spec-#{source.hash}.cr"
  ws = ws_with_doc(uri, source)
  result = CrystalLanguageServer::Handlers::SemanticTokens.handle(ws,
    JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}})))
  CrystalLanguageServer::Handlers::SemanticTokens.drop(uri)
  data = result[:data]
  slices = [] of {type_idx: Int32, modifiers: Int32}
  (0...data.size).step(5) do |i|
    slices << {type_idx: data[i + 3], modifiers: data[i + 4]}
  end
  slices
end

private def declaration_bit
  1 << CrystalLanguageServer::Handlers::SemanticTokens::MODIFIER_IDX["declaration"]
end

private def readonly_bit
  1 << CrystalLanguageServer::Handlers::SemanticTokens::MODIFIER_IDX["readonly"]
end

private def default_library_bit
  1 << CrystalLanguageServer::Handlers::SemanticTokens::MODIFIER_IDX["defaultLibrary"]
end

describe "SemanticTokens modifiers" do
  it "flags Constant tokens with the readonly modifier" do
    toks = tokens_for("FOO = 1\n")
    foo = toks.find { |t| t[:type_idx] == CrystalLanguageServer::Handlers::SemanticTokens::TYPE_IDX["type"] }
    foo.should_not be_nil
    (foo.not_nil![:modifiers] & readonly_bit).should eq readonly_bit
  end

  it "flags stdlib types with defaultLibrary" do
    toks = tokens_for("x = Array.new\n")
    array_tok = toks.find { |t| t[:type_idx] == CrystalLanguageServer::Handlers::SemanticTokens::TYPE_IDX["type"] }
    array_tok.should_not be_nil
    (array_tok.not_nil![:modifiers] & default_library_bit).should eq default_library_bit
  end

  it "flags the declaration site of a class name" do
    toks = tokens_for("class Fooz\nend\n")
    fooz = toks.find { |t| t[:type_idx] == CrystalLanguageServer::Handlers::SemanticTokens::TYPE_IDX["type"] }
    fooz.should_not be_nil
    (fooz.not_nil![:modifiers] & declaration_bit).should eq declaration_bit
  end
end
