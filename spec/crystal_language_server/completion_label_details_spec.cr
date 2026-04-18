require "../spec_helper"

describe "Completion labelDetails" do
  it "attaches signature + return type to a callable completion" do
    uri = "file:///labeldetails.cr"
    source = "def enqueue_packet(id : Int32, payload : String) : Bool\nend\n\nenqu\n"
    ws = ws_with_doc(uri, source)

    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "position": {"line": 3, "character": 4},
      "context": {"triggerKind": 1}
    }))
    items = CrystalLanguageServer::Handlers::Completion.handle(ws, params)[:items]

    item = items.find { |i| i["label"].as_s == "enqueue_packet" }
    item.should_not be_nil
    raise "unreachable" unless item

    details = item["labelDetails"]?
    details.should_not be_nil
    raise "unreachable" unless details

    details["detail"].as_s.should contain("id : Int32")
    details["description"].as_s.should eq "Bool"
  end

  it "labels a class completion with `class`" do
    uri = "file:///labeldetails-class.cr"
    source = "class MyThing\nend\n\nMyThi\n"
    ws = ws_with_doc(uri, source)

    params = JSON.parse(%({
      "textDocument": {"uri": #{uri.to_json}},
      "position": {"line": 3, "character": 5},
      "context": {"triggerKind": 1}
    }))
    items = CrystalLanguageServer::Handlers::Completion.handle(ws, params)[:items]
    thing = items.find { |i| i["label"].as_s == "MyThing" }
    thing.should_not be_nil
    raise "unreachable" unless thing
    thing["labelDetails"]["description"].as_s.should eq "class"
  end
end
