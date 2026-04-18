require "../spec_helper"

describe CrystalLanguageServer::Scanner do
  it "tokenizes keywords, identifiers, numbers, and comments" do
    tokens = CrystalLanguageServer::Scanner.tokenize(<<-CR)
      # comment
      class Foo
        def bar : Int32
          42
        end
      end
      CR

    kinds = tokens.reject { |t|
      t.kind.in?(CrystalLanguageServer::Scanner::Token::Kind::Whitespace,
        CrystalLanguageServer::Scanner::Token::Kind::Newline)
    }.map(&.kind)

    kinds.should contain(CrystalLanguageServer::Scanner::Token::Kind::Comment)
    kinds.should contain(CrystalLanguageServer::Scanner::Token::Kind::Keyword)
    kinds.should contain(CrystalLanguageServer::Scanner::Token::Kind::Constant)
    kinds.should contain(CrystalLanguageServer::Scanner::Token::Kind::Number)
  end

  it "extracts nested class/def symbols" do
    src = <<-CR
      module Outer
        class Inner
          def hello(name : String)
            name
          end
        end
      end
      CR
    roots = CrystalLanguageServer::Scanner.document_symbols(src)
    roots.size.should eq 1
    roots[0].name.should eq "Outer"
    roots[0].children.size.should eq 1
    inner = roots[0].children[0]
    inner.name.should eq "Inner"
    inner.children.size.should eq 1
    inner.children[0].name.should eq "hello"
  end

  it "handles qualified names" do
    src = "class Foo::Bar\nend"
    roots = CrystalLanguageServer::Scanner.document_symbols(src)
    roots[0].name.should eq "Foo::Bar"
  end

  it "finds the identifier under a cursor" do
    src = "hello_world"
    CrystalLanguageServer::Scanner.word_at(src, 0).should eq "hello_world"
    CrystalLanguageServer::Scanner.word_at(src, 5).should eq "hello_world"
    CrystalLanguageServer::Scanner.word_at(src, src.bytesize).should eq "hello_world"
  end

  it "does not treat string contents as tokens" do
    tokens = CrystalLanguageServer::Scanner.tokenize(%q("hello world" end))
    strings = tokens.select { |t| t.kind == CrystalLanguageServer::Scanner::Token::Kind::String }
    strings.size.should eq 1
    # `end` outside the string still tokenizes as a keyword
    tokens.any? { |t| t.kind == CrystalLanguageServer::Scanner::Token::Kind::Keyword && t.text == "end" }.should be_true
  end
end
