require "spec"
require "../src/symbol_index"

describe Kodkod::SymbolIndex do
  it "indexes and looks up definitions by name" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/a.cr", [
      Kodkod::SymbolIndex::Def.new("foo", :method, "/w/a.cr", 3, 4),
    ])
    defs = idx.lookup("foo")
    defs.size.should eq(1)
    defs.first.path.should eq("/w/a.cr")
    defs.first.line.should eq(3)
    idx.has_name?("foo").should be_true
    idx.has_name?("bar").should be_false
  end

  it "replaces a file's definitions wholesale" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/a.cr", [
      Kodkod::SymbolIndex::Def.new("foo", :method, "/w/a.cr", 1, 4),
      Kodkod::SymbolIndex::Def.new("bar", :method, "/w/a.cr", 5, 4),
    ])
    idx.lookup("foo").size.should eq(1)
    idx.replace("/w/a.cr", [
      Kodkod::SymbolIndex::Def.new("baz", :method, "/w/a.cr", 9, 4),
    ])
    idx.lookup("foo").should be_empty
    idx.lookup("bar").should be_empty
    idx.lookup("baz").size.should eq(1)
    idx.files_indexed.should eq(1)
    idx.def_count.should eq(1)
  end

  it "keeps same-name definitions from other files on replace" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/a.cr", [Kodkod::SymbolIndex::Def.new("foo", :method, "/w/a.cr", 1, 4)])
    idx.replace("/w/b.cr", [Kodkod::SymbolIndex::Def.new("foo", :method, "/w/b.cr", 2, 4)])
    idx.lookup("foo").size.should eq(2)
    idx.replace("/w/a.cr", [] of Kodkod::SymbolIndex::Def)
    defs = idx.lookup("foo")
    defs.size.should eq(1)
    defs.first.path.should eq("/w/b.cr")
  end

  it "removes a file and prunes empty name buckets" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/a.cr", [Kodkod::SymbolIndex::Def.new("foo", :method, "/w/a.cr", 1, 4)])
    idx.remove("/w/a.cr")
    idx.lookup("foo").should be_empty
    idx.files_indexed.should eq(0)
  end

  it "removes a whole directory prefix" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/src/a.cr", [Kodkod::SymbolIndex::Def.new("a", :method, "/w/src/a.cr", 1, 4)])
    idx.replace("/w/src/sub/b.cr", [Kodkod::SymbolIndex::Def.new("b", :method, "/w/src/sub/b.cr", 1, 4)])
    idx.replace("/w/lib.c", [Kodkod::SymbolIndex::Def.new("c", :function, "/w/lib.c", 1, 0)])
    idx.remove_prefix("/w/src")
    idx.has_name?("a").should be_false
    idx.has_name?("b").should be_false
    idx.has_name?("c").should be_true
  end

  it "bumps version on every mutation" do
    idx = Kodkod::SymbolIndex.new
    v0 = idx.version
    idx.replace("/w/a.cr", [Kodkod::SymbolIndex::Def.new("foo", :method, "/w/a.cr", 1, 4)])
    idx.version.should_not eq(v0)
    v1 = idx.version
    idx.remove("/w/a.cr")
    idx.version.should_not eq(v1)
  end
end
