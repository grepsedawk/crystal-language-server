require "../spec_helper"

# These specs exercise the compiler-facing surface that both
# Subprocess and Embedded must implement. Anything that needs a
# real compile is gated on `crystal` being on PATH — so CI runners
# without a compiler skip them cleanly rather than failing.
describe CrystalLanguageServer::Compiler do
  describe ".default" do
    it "picks Subprocess when mode is unset" do
      prev = ENV["CRYSTAL_LANGUAGE_SERVER_MODE"]?
      ENV.delete("CRYSTAL_LANGUAGE_SERVER_MODE")
      begin
        provider = CrystalLanguageServer::Compiler.default(CrystalLanguageServer::Options.new)
        provider.should be_a(CrystalLanguageServer::Compiler::Subprocess)
      ensure
        ENV["CRYSTAL_LANGUAGE_SERVER_MODE"] = prev if prev
      end
    end

    it "picks Subprocess when mode=subprocess" do
      ENV["CRYSTAL_LANGUAGE_SERVER_MODE"] = "subprocess"
      begin
        provider = CrystalLanguageServer::Compiler.default(CrystalLanguageServer::Options.new)
        provider.should be_a(CrystalLanguageServer::Compiler::Subprocess)
      ensure
        ENV.delete("CRYSTAL_LANGUAGE_SERVER_MODE")
      end
    end

    it "falls back to Subprocess when embedded isn't available" do
      ENV["CRYSTAL_LANGUAGE_SERVER_MODE"] = "embedded"
      begin
        provider = CrystalLanguageServer::Compiler.default(CrystalLanguageServer::Options.new)
        # Either the binary was built embedded (Embedded) or it wasn't
        # (Subprocess fallback). Both paths are acceptable; what matters
        # is we get *a* provider back, never nil.
        provider.should be_a(CrystalLanguageServer::Compiler::Provider)
      ensure
        ENV.delete("CRYSTAL_LANGUAGE_SERVER_MODE")
      end
    end
  end

  describe "EntrypointResolver" do
    it "returns nil when no shard.yml exists upwards" do
      tmp = File.tempfile(suffix: ".cr")
      begin
        File.write(tmp.path, "x = 1\n")
        CrystalLanguageServer::Compiler::EntrypointResolver.for_file(tmp.path).should be_nil
      ensure
        tmp.delete rescue nil
      end
    end

    it "finds the entrypoint declared by shard.yml targets" do
      dir = File.tempname("crystal-lsp-entry-spec")
      Dir.mkdir_p(File.join(dir, "src"))
      begin
        File.write(File.join(dir, "shard.yml"), <<-YML)
          name: widget
          version: 0.1.0
          targets:
            widget:
              main: src/widget.cr
          YML
        File.write(File.join(dir, "src", "widget.cr"), "# entry\n")
        File.write(File.join(dir, "src", "helper.cr"), "# helper\n")

        entry = CrystalLanguageServer::Compiler::EntrypointResolver.for_file(File.join(dir, "src", "helper.cr"))
        entry.should eq(File.join(dir, "src", "widget.cr"))
      ensure
        # Purge the cache so repeated specs don't see stale data.
        FileUtils.rm_rf(dir) rescue nil
      end
    end

    it "falls back to src/<name>.cr when no target is declared" do
      dir = File.tempname("crystal-lsp-entry-fallback")
      Dir.mkdir_p(File.join(dir, "src"))
      begin
        File.write(File.join(dir, "shard.yml"), "name: inferred\nversion: 0.1.0\n")
        File.write(File.join(dir, "src", "inferred.cr"), "# entry\n")

        entry = CrystalLanguageServer::Compiler::EntrypointResolver.for_file(File.join(dir, "src", "other.cr"))
        # `other.cr` doesn't exist, but the resolver only cares that
        # shard.yml resolves — the returned entry must be `inferred.cr`.
        entry.should eq(File.join(dir, "src", "inferred.cr"))
      ensure
        FileUtils.rm_rf(dir) rescue nil
      end
    end
  end

  describe "BuildError" do
    it "round-trips through JSON with the compiler's own schema" do
      json = %q({"file":"x.cr","line":5,"column":3,"size":4,"message":"boom"})
      err = CrystalLanguageServer::Compiler::BuildError.from_json(json)
      err.file.should eq "x.cr"
      err.line.should eq 5
      err.column.should eq 3
      err.size.should eq 4
      err.message.should eq "boom"
    end
  end

  describe "Subprocess" do
    it "formats valid source via `crystal tool format`" do
      next if !crystal_available?
      provider = CrystalLanguageServer::Compiler::Subprocess.new
      formatted = provider.format("def  foo  ;end")
      formatted.should_not be_nil
      formatted.as(String).should contain("def foo")
    end

    it "returns nil when format input has a syntax error" do
      next if !crystal_available?
      provider = CrystalLanguageServer::Compiler::Subprocess.new
      provider.format("def foo(").should be_nil
    end

    it "extracts types at a cursor via context" do
      next if !crystal_available?
      provider = CrystalLanguageServer::Compiler::Subprocess.new
      source = <<-CR
        def greet(who : String) : String
          "hello, \#{who}"
        end

        greet("world")
        CR

      dir = File.tempname("cls-ctx-spec")
      Dir.mkdir_p(dir)
      path = File.join(dir, "main.cr")
      begin
        File.write(path, source)
        # cursor on the `greet` call site, line 5 column 1 (1-based)
        json = provider.context(path, source, 5, 1)
        json.should_not be_nil
        json = json.not_nil!
        json["status"].as_s.should eq "ok"
      ensure
        FileUtils.rm_rf(dir) rescue nil
      end
    end

    it "locates definitions via implementations" do
      next if !crystal_available?
      provider = CrystalLanguageServer::Compiler::Subprocess.new
      source = <<-CR
        def greet(who : String) : String
          "hello, \#{who}"
        end

        greet("world")
        CR

      dir = File.tempname("cls-impl-spec")
      Dir.mkdir_p(dir)
      path = File.join(dir, "main.cr")
      begin
        File.write(path, source)
        # cursor on the `greet` call at line 5 column 1
        json = provider.implementations(path, source, 5, 1)
        json.should_not be_nil
        json = json.not_nil!
        json["status"].as_s.should eq "ok"

        impls = json["implementations"].as_a
        impls.size.should be >= 1
        impls.first["filename"].as_s.should end_with("main.cr")
      ensure
        FileUtils.rm_rf(dir) rescue nil
      end
    end

    it "reports compile errors as structured BuildError entries" do
      next if !crystal_available?
      provider = CrystalLanguageServer::Compiler::Subprocess.new
      # An unknown method — the compiler will reject.
      source = "undefined_method_please\n"
      errors = provider.build_diagnostics("", source)
      errors.size.should be >= 1
      errors.first.message.should contain("undefined")
    end
  end
end

require "file_utils"

private def crystal_available? : Bool
  Process.run("crystal", ["--version"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end
