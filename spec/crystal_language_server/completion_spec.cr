require "../spec_helper"
require "file_utils"

private def at(line : Int32, character : Int32, uri : String)
  JSON.parse(%({"textDocument":{"uri":#{uri.to_json}},"position":{"line":#{line},"character":#{character}}}))
end

describe CrystalLanguageServer::Handlers::Completion do
  describe "snippet insertText" do
    it "emits a snippet for methods with required positional args" do
      sig = "def greet(name, who : String)"
      args = CrystalLanguageServer::Handlers::Completion.required_arg_names(sig)
      args.should eq ["name", "who"]
    end

    it "skips args with defaults, splats, and blocks" do
      sig = "def call(req, opts = {} of String => String, *rest, &block)"
      CrystalLanguageServer::Handlers::Completion.required_arg_names(sig).should eq ["req"]
    end

    it "returns an empty array for arg-less defs" do
      CrystalLanguageServer::Handlers::Completion.required_arg_names("def foo").should be_empty
      CrystalLanguageServer::Handlers::Completion.required_arg_names("def foo()").should be_empty
    end

    it "ignores commas inside parameter type expressions" do
      sig = "def merge(a : Hash(String, Int32), b : Array(Int32))"
      CrystalLanguageServer::Handlers::Completion.required_arg_names(sig).should eq ["a", "b"]
    end
  end

  describe "auto-require for cross-file symbols" do
    it "proposes an `additionalTextEdits` require when an out-of-file class matches" do
      dir = File.tempname("cls-completion-require-spec")
      Dir.mkdir_p(File.join(dir, "src"))
      lib_path = File.join(dir, "src", "library.cr")
      main_path = File.join(dir, "src", "main.cr")

      File.write(lib_path, "class WidgetFactory\nend\n")
      main_source = "Widget"
      File.write(main_path, main_source)

      begin
        ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
        ws.root_path = dir
        uri = CrystalLanguageServer::DocumentUri.from_path(main_path)
        ws.documents.open(uri, main_source, 1, "crystal")

        params = at(0, main_source.size, uri)
        result = CrystalLanguageServer::Handlers::Completion.handle(ws, params)

        items = result[:items].as(Array)
        widget = items.find { |i| i["label"].as_s == "WidgetFactory" }
        widget.should_not be_nil
        widget = widget.not_nil!

        edits = widget["additionalTextEdits"]?.try(&.as_a)
        edits.should_not be_nil
        new_text = edits.not_nil!.first["newText"].as_s
        new_text.should contain(%(require "./library"))

        widget["data"]?.try(&.["file"]?.try(&.as_s)).should eq lib_path
      ensure
        FileUtils.rm_rf(dir) rescue nil
      end
    end

    it "skips the require edit when the buffer already requires the target" do
      dir = File.tempname("cls-completion-already-required")
      Dir.mkdir_p(File.join(dir, "src"))
      lib_path = File.join(dir, "src", "library.cr")
      main_path = File.join(dir, "src", "main.cr")

      File.write(lib_path, "class AlreadyKnown\nend\n")
      main_source = %(require "./library"\nAlready)
      File.write(main_path, main_source)

      begin
        ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
        ws.root_path = dir
        uri = CrystalLanguageServer::DocumentUri.from_path(main_path)
        ws.documents.open(uri, main_source, 1, "crystal")

        params = at(1, "Already".size, uri)
        result = CrystalLanguageServer::Handlers::Completion.handle(ws, params)

        items = result[:items].as(Array)
        hit = items.find { |i| i["label"].as_s == "AlreadyKnown" }
        hit.should_not be_nil
        hit.not_nil!["additionalTextEdits"]?.should be_nil
      ensure
        FileUtils.rm_rf(dir) rescue nil
      end
    end
  end

  describe "completionItem/resolve" do
    it "fills documentation from the def's preceding `#` comments" do
      dir = File.tempname("cls-completion-resolve-spec")
      Dir.mkdir_p(dir)
      target = File.join(dir, "things.cr")
      File.write(target, <<-CR)
        # Greets the given name in plain English.
        # Returns a String.
        def hello(name)
          "hi \#{name}"
        end
        CR

      begin
        ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)

        item = JSON.parse(%({
          "label": "hello",
          "kind": 2,
          "data": {"file": #{target.to_json}, "line": 3}
        }))

        resolved = CrystalLanguageServer::Handlers::Completion.resolve(ws, item)
        json = resolved.as(JSON::Any)

        doc = json["documentation"]?
        doc.should_not be_nil
        doc.not_nil!["kind"].as_s.should eq "markdown"
        doc.not_nil!["value"].as_s.should contain("Greets the given name")
      ensure
        FileUtils.rm_rf(dir) rescue nil
      end
    end

    it "round-trips the item unchanged when no `data` field is set" do
      ws = CrystalLanguageServer::Workspace.new(CrystalLanguageServer::Options.new)
      item = JSON.parse(%({"label":"foo","kind":14}))

      resolved = CrystalLanguageServer::Handlers::Completion.resolve(ws, item)
      json = resolved.as(JSON::Any)
      json["label"].as_s.should eq "foo"
      json["documentation"]?.should be_nil
    end
  end

  describe "lifecycle advertises new capabilities" do
    it "marks completion resolveProvider true" do
      caps = CrystalLanguageServer::Handlers::Lifecycle.capabilities
      caps[:completionProvider][:resolveProvider].should be_true
    end
  end
end
