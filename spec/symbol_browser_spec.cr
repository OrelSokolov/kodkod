require "spec"
require "../src/symbol_index"
require "../src/symbol_browser"

def d(name, path, line = 0)
  Kodkod::SymbolIndex::Def.new(name, :method, path, line, 0)
end

describe Kodkod::SymbolBrowser do
  it "matches the query against BOTH cells: name and file" do
    def0 = d("helper", "/w/src/app.cr")
    # Name cell.
    Kodkod::SymbolBrowser.matches?(def0, "hel", "src/app.cr").should be_true
    Kodkod::SymbolBrowser.matches?(def0, "HELPER", "src/app.cr").should be_true
    # File cell — path fragments match too.
    Kodkod::SymbolBrowser.matches?(def0, "app.cr", "src/app.cr").should be_true
    Kodkod::SymbolBrowser.matches?(def0, "src/", "src/app.cr").should be_true
    # In neither cell.
    Kodkod::SymbolBrowser.matches?(def0, "zzz", "src/app.cr").should be_false
    # The query spans a boundary (name end + file start) — no match.
    Kodkod::SymbolBrowser.matches?(def0, "helperapp", "src/app.cr").should be_false
    # Empty query shows everything.
    Kodkod::SymbolBrowser.matches?(def0, "", "src/app.cr").should be_true
  end

  it "filters rows by name or file through the workspace-relative path" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/src/app.cr", [d("helper", "/w/src/app.cr")])
    idx.replace("/w/lib/other.cr", [d("zappa", "/w/lib/other.cr")])
    b = Kodkod::SymbolBrowser.new(idx)
    b.root = "/w"

    b.query = ""
    b.rows.size.should eq(2)

    b.query = "helper" # by name
    b.rows.size.should eq(1)
    b.rows.first.name.should eq("helper")

    b.query = "lib/" # by file cell only
    b.rows.size.should eq(1)
    b.rows.first.name.should eq("zappa")

    b.query = "app.cr" # the file cell, not the name
    b.rows.size.should eq(1)
    b.rows.first.name.should eq("helper")

    b.query = "nomatch"
    b.rows.should be_empty
  end

  it "keeps rows sorted file-then-line and caches until the index moves" do
    idx = Kodkod::SymbolIndex.new
    idx.replace("/w/b.cr", [d("late", "/w/b.cr", 9)])
    idx.replace("/w/a.cr", [d("second", "/w/a.cr", 5),
                            d("first", "/w/a.cr", 1)])
    b = Kodkod::SymbolBrowser.new(idx)
    b.rows.map(&.name).should eq(["first", "second", "late"])
    cached = b.rows
    cached.same?(b.rows).should be_true # stable until query/version change

    idx.replace("/w/c.cr", [d("new", "/w/c.cr")])
    b.rows.size.should eq(4) # version bump re-filters
  end
end
