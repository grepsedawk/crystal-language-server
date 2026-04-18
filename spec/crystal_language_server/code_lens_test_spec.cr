require "../spec_helper"

private def test_lenses(lenses)
  lenses.compact_map { |l| l.as?(CrystalLanguageServer::Handlers::CodeLens::TestLens) }
end

describe CrystalLanguageServer::Handlers::CodeLens do
  it "emits a ▶ Run lens for each it/describe/context in a spec file" do
    source = <<-CR
      require "./spec_helper"

      describe "Adder" do
        it "adds two numbers" do
          (1 + 1).should eq 2
        end

        context "when given strings" do
          it("concatenates") do
            ("a" + "b").should eq "ab"
          end
        end
      end

      class Helper
        def self.build
          Helper.new
        end
      end
      CR

    uri = "file:///tmp/adder_spec.cr"
    ws = ws_with_doc(uri, source)
    params = JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}}))
    lenses = CrystalLanguageServer::Handlers::CodeLens.handle(ws, params)

    runs = test_lenses(lenses)
    runs.size.should eq 4
    runs.map(&.[:command].[:title]).uniq.should eq ["\u25B6 Run"]
    runs.map(&.[:command].[:command]).uniq.should eq ["crystal.runSpec"]

    # describe "Adder" sits on line 3 in the buffer; 1-based.
    first = runs.first
    first[:command][:arguments][0].should eq uri
    first[:command][:arguments][1].should eq 3
    first[:command][:arguments][2].should eq "Adder"

    # Nested `it "adds two numbers"` is the next example.
    runs[1][:command][:arguments][2].should eq "adds two numbers"

    # Parenthesized `it("concatenates")` is still captured.
    runs.map { |r| r[:command][:arguments][2] }.should contain("concatenates")
  end

  it "does not emit test lenses on non-spec files" do
    source = <<-CR
      describe "something" do
        it "does a thing" do
        end
      end
      CR
    uri = "file:///tmp/main.cr"
    ws = ws_with_doc(uri, source)
    params = JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}}))
    lenses = CrystalLanguageServer::Handlers::CodeLens.handle(ws, params)
    test_lenses(lenses).should be_empty
  end

  it "ignores it/describe/context that are not line-leading" do
    source = <<-CR
      class Thing
        def it(name)
          name
        end

        def check
          self.it "not a spec"
        end
      end
      CR
    uri = "file:///tmp/thing_spec.cr"
    ws = ws_with_doc(uri, source)
    params = JSON.parse(%({"textDocument":{"uri":#{uri.to_json}}}))
    lenses = CrystalLanguageServer::Handlers::CodeLens.handle(ws, params)
    test_lenses(lenses).should be_empty
  end
end
