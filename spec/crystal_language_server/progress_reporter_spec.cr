require "../spec_helper"

describe CrystalLanguageServer::ProgressReporter do
  it "emits begin/report/end as `$/progress` notifications with the token and value kind" do
    output = IO::Memory.new
    transport = CrystalLanguageServer::Transport.new(IO::Memory.new, output)
    reporter = CrystalLanguageServer::ProgressReporter.new(transport, "tok-1", "Indexing")

    reporter.begin("starting", percentage: 0)
    reporter.report("50%", percentage: 50)
    reporter.end_("done")

    messages = drain_transport(output)
    messages.size.should eq 3
    messages.all? { |m| m["method"].as_s == "$/progress" }.should be_true
    messages.all? { |m| m["params"]["token"].as_s == "tok-1" }.should be_true

    messages[0]["params"]["value"]["kind"].as_s.should eq "begin"
    messages[0]["params"]["value"]["title"].as_s.should eq "Indexing"
    messages[1]["params"]["value"]["kind"].as_s.should eq "report"
    messages[1]["params"]["value"]["percentage"].as_i.should eq 50
    messages[2]["params"]["value"]["kind"].as_s.should eq "end"
  end
end
