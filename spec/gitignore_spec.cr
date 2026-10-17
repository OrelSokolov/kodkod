require "spec"
require "../src/gitignore"

describe Kodkod::Gitignore do
  it "parses an empty or missing file as no rules" do
    Kodkod::Gitignore.new("").empty?.should be_true
    Kodkod::Gitignore.load("/nonexistent/.gitignore").should be_nil
  end

  it "skips comments and blank lines" do
    gi = Kodkod::Gitignore.new("# comment\n\n  \n*.o\n")
    gi.ignores?("build.o").should be_true
    gi.ignores?("#", false).should be_false
  end

  it "matches simple names at any depth" do
    gi = Kodkod::Gitignore.new("tmp\n")
    gi.ignores?("tmp").should be_true
    gi.ignores?("a/b/tmp").should be_true
    gi.ignores?("tmpx").should be_false
  end

  it "matches a basename only as a whole segment" do
    gi = Kodkod::Gitignore.new("o\n")
    gi.ignores?("foo.txt").should be_false
    gi.ignores?("a/o").should be_true
  end

  it "anchors patterns with a slash" do
    gi = Kodkod::Gitignore.new("/build\n")
    gi.ignores?("build").should be_true
    gi.ignores?("src/build").should be_false

    gi = Kodkod::Gitignore.new("doc/frotz/\n")
    gi.ignores?("doc/frotz", dir: true).should be_true
    gi.ignores?("doc/frotz", dir: false).should be_false
    gi.ignores?("sub/doc/frotz", dir: true).should be_false
  end

  it "honors dir-only rules" do
    gi = Kodkod::Gitignore.new("logs/\n")
    gi.ignores?("logs", dir: true).should be_true
    gi.ignores?("logs", dir: false).should be_false
    gi.ignores?("a/logs", dir: true).should be_true
  end

  it "negates with ! and lets the last match win" do
    gi = Kodkod::Gitignore.new("*.log\n!important.log\n")
    gi.ignores?("debug.log").should be_true
    gi.ignores?("important.log").should be_false

    gi = Kodkod::Gitignore.new("!important.log\n*.log\n")
    gi.ignores?("important.log").should be_true
  end

  it "supports * and ? without crossing slashes" do
    gi = Kodkod::Gitignore.new("*.tmp\n?.txt\n")
    gi.ignores?("a.tmp").should be_true
    gi.ignores?("a/b.tmp").should be_true
    gi.ignores?("a.b.tmp").should be_true
    gi.ignores?("a/b.c.tmp").should be_true # * matches within the basename

    gi = Kodkod::Gitignore.new("a/*\n")
    gi.ignores?("a/x").should be_true
    gi.ignores?("a/x/y").should be_false # * never crosses a slash
    gi.ignores?("x.txt").should be_false
    gi.ignores?("xy.txt").should be_false
  end

  it "supports character classes" do
    gi = Kodkod::Gitignore.new("cache[0-9].dat\n[!a]*.md\n")
    gi.ignores?("cache7.dat").should be_true
    gi.ignores?("cachex.dat").should be_false
    gi.ignores?("beta.md").should be_true
    gi.ignores?("apple.md").should be_false
  end

  it "supports the ** forms" do
    gi = Kodkod::Gitignore.new("**/logs\n")
    gi.ignores?("logs").should be_true
    gi.ignores?("a/b/logs").should be_true

    gi = Kodkod::Gitignore.new("build/**\n")
    gi.ignores?("build/x.o", dir: false).should be_true
    gi.ignores?("build", dir: true).should be_false # only what is INSIDE

    gi = Kodkod::Gitignore.new("a/**/b\n")
    gi.ignores?("a/b").should be_true
    gi.ignores?("a/x/y/b").should be_true
  end

  it "treats an escaped leading # or ! literally" do
    gi = Kodkod::Gitignore.new("\\#notes\n\\!bang\n")
    gi.ignores?("#notes").should be_true
    gi.ignores?("!bang").should be_true
  end
end
