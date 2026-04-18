require "../spec_helper"

describe CrystalLanguageServer::Document do
  it "maps positions to offsets for ASCII" do
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "one\ntwo\nthree\n")
    doc.position_to_offset(0, 0).should eq 0
    doc.position_to_offset(1, 0).should eq 4
    doc.position_to_offset(2, 4).should eq 12
  end

  it "round-trips offsets through positions" do
    text = "abc\ndef\nghi"
    doc = CrystalLanguageServer::Document.new("file:///a.cr", text)
    (0..text.bytesize).each do |off|
      pos = doc.offset_to_position(off)
      doc.position_to_offset(pos.line, pos.character).should eq off
    end
  end

  it "handles UTF-16 code units for astral characters" do
    # 🦀 is U+1F980 — 2 UTF-16 code units, 4 UTF-8 bytes.
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "🦀x")
    # After the crab emoji, the character column in UTF-16 is 2.
    doc.position_to_offset(0, 2).should eq 4
    doc.offset_to_position(4).character.should eq 2
  end

  it "applies a full content replacement" do
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "old")
    doc.apply_change(JSON.parse(%q({"text":"new"})))
    doc.text.should eq "new"
  end

  it "applies a range-based change" do
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "hello world")
    change = JSON.parse(%q({"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"text":"crystal"}))
    doc.apply_change(change)
    doc.text.should eq "hello crystal"
  end

  it "memoizes tokens and symbols across calls" do
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "class Foo\n  def bar\n  end\nend\n")
    doc.tokens.should be(doc.tokens)
    doc.symbols.should be(doc.symbols)
  end

  it "invalidates the scanner cache on text= and apply_change" do
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "class Foo\nend\n")
    first_tokens = doc.tokens
    first_symbols = doc.symbols
    first_symbols.map(&.name).should eq ["Foo"]

    doc.apply_change(JSON.parse(%q({"text":"class Bar\nend\n"})))

    doc.tokens.should_not be(first_tokens)
    doc.symbols.should_not be(first_symbols)
    doc.symbols.map(&.name).should eq ["Bar"]
  end

  it "invalidates the scanner cache on update" do
    doc = CrystalLanguageServer::Document.new("file:///a.cr", "class Foo\nend\n")
    doc.symbols.map(&.name).should eq ["Foo"]
    doc.update("module Baz\nend\n", 2)
    doc.symbols.map(&.name).should eq ["Baz"]
    doc.version.should eq 2
  end
end
