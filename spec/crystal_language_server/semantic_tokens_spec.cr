require "../spec_helper"

describe CrystalLanguageServer::Handlers::SemanticTokens do
  it "returns a resultId with the full payload" do
    uri = "file:///tok1.cr"
    ws = ws_with_doc(uri, "def foo\nend\n")
    params = JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}}))

    result = CrystalLanguageServer::Handlers::SemanticTokens.handle(ws, params)
    result[:resultId].should_not be_empty
    result[:data].should_not be_empty
  ensure
    CrystalLanguageServer::Handlers::SemanticTokens.drop(uri) if uri
  end

  it "delta returns edits when the prior result is known" do
    uri = "file:///tok2.cr"
    ws = ws_with_doc(uri, "def foo\nend\n")
    full = CrystalLanguageServer::Handlers::SemanticTokens.handle(ws,
      JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}})))

    ws.documents.with_document(uri) do |doc|
      doc.update("def bar\nend\n", 2)
    end

    delta = CrystalLanguageServer::Handlers::SemanticTokens.handle_delta(ws,
      JSON.parse(%({"textDocument":{"uri":#{uri.to_json}},"previousResultId":#{full[:resultId].to_json}})))

    payload = JSON.parse(delta.to_json)
    payload["edits"]?.should_not be_nil
    payload["resultId"].as_s.should_not eq full[:resultId]
  ensure
    CrystalLanguageServer::Handlers::SemanticTokens.drop(uri) if uri
  end

  it "delta falls back to full data when previousResultId is unknown" do
    uri = "file:///tok3.cr"
    ws = ws_with_doc(uri, "def foo\nend\n")
    delta = CrystalLanguageServer::Handlers::SemanticTokens.handle_delta(ws,
      JSON.parse(%({"textDocument":{"uri":#{uri.to_json}},"previousResultId":"unknown-xyz"})))

    payload = JSON.parse(delta.to_json)
    payload["data"]?.should_not be_nil
    payload["data"].as_a.should_not be_empty
  ensure
    CrystalLanguageServer::Handlers::SemanticTokens.drop(uri) if uri
  end
end
