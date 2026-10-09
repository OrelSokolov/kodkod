require "spec"
require "file_utils"
require "../src/quick_open"

# A Ruby-style mktempdir (Crystal has none): unique dir under the
# system tempdir, removed after the block.
def with_temp_dir(& : String ->)
  dir = File.join(Dir.tempdir,
    "kodkod-spec-#{Random.new.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_r(dir) rescue nil
  end
end

describe Kodkod::QuickOpen do
  describe ".files_under" do
    it "collects workspace files as sorted relative paths" do
      with_temp_dir do |dir|
        File.touch(File.join(dir, "app.cr"))
        Dir.mkdir(File.join(dir, "src"))
        File.touch(File.join(dir, "src", "vim_mode.cr"))
        Dir.mkdir(File.join(dir, "src", "syntax"))
        File.touch(File.join(dir, "src", "syntax", "engine.cr"))
        Kodkod::QuickOpen.files_under(dir, show_hidden: false)
          .should eq(["app.cr", "src/syntax/engine.cr", "src/vim_mode.cr"])
      end
    end

    it "skips hidden entries and .git unless show_hidden is set" do
      with_temp_dir do |dir|
        Dir.mkdir(File.join(dir, ".git"))
        File.touch(File.join(dir, ".git", "config"))
        Dir.mkdir(File.join(dir, ".cache"))
        File.touch(File.join(dir, ".cache", "x.bin"))
        File.touch(File.join(dir, ".hidden"))
        File.touch(File.join(dir, "visible.txt"))
        Kodkod::QuickOpen.files_under(dir, show_hidden: false)
          .should eq(["visible.txt"])
        # .git stays hidden even with show_hidden — it is never a
        # search target, just noise.
        Kodkod::QuickOpen.files_under(dir, show_hidden: true)
          .should eq([".cache/x.bin", ".hidden", "visible.txt"])
      end
    end
  end

  describe ".rank" do
    it "returns the files in natural order for an empty query" do
      files = ["b.txt", "a.txt"]
      rows = Kodkod::QuickOpen.rank(files, "")
      rows.map(&.[0]).should eq(["b.txt", "a.txt"])
      rows.map(&.[1]).should eq([nil, nil])
    end

    it "filters and ranks by fuzzy score, best first" do
      files = ["src/app.cr", "src/rope.cr", "README.md"]
      rows = Kodkod::QuickOpen.rank(files, "apc")
      rows.map(&.[0]).should eq(["src/app.cr"])
      # The match result carries the positions (for highlighting).
      rows[0][1].should_not be_nil
    end

    it "caps the visible rows" do
      files = (1..50).map { |i| "file#{i}.txt" }
      Kodkod::QuickOpen.rank(files, "file").size.should eq(
        Kodkod::QuickOpen::MAX_ROWS)
    end
  end

  describe "#rows (incremental narrowing)" do
    it "keeps ranking identical to a full re-filter while typing" do
      files = ["src/app.cr", "src/rope.cr", "src/syntax/engine.cr",
               "app/views/home.html", "README.md", "spec/app_spec.cr"]
      q = Kodkod::QuickOpen.new
      q.files = files
      # type "s", then extend to "sr" (narrowed over "s"'s survivors),
      # then backspace to "s" again (full re-gate — not a prefix).
      {"s", "sr", "s"}.each do |query|
        q.query = query
        expected = Kodkod::QuickOpen.rank(files, query).map(&.[0])
        q.rows.map(&.[0]).should eq(expected)
      end
    end

    it "matches everything for an empty query and caches per query" do
      q = Kodkod::QuickOpen.new
      q.files = ["b.txt", "a.txt", "c.txt"]
      q.rows.map(&.[0]).should eq(["b.txt", "a.txt", "c.txt"])
      q.rows.same?(q.rows).should be_true # cached, not recomputed
    end
  end

  describe Kodkod::QuickOpen::Scorer do
    it "scores identically to Fuzzy.match" do
      scorer = Kodkod::QuickOpen::Scorer.new(32)
      texts = ["src/app.cr", "glm-4.5", "glm-4.5-air", "a___i___r",
               "x-g-l-m", "glmFour", "glmfour", "README.md", "spec/syntax/engine.cr"]
      queries = ["a", "g", "glm", "air", "gf", "g45", "sre", "src", "zzz"]
      checked = 0
      queries.each do |q|
        texts.each do |t|
          expected = Kodkod::Fuzzy.match(q, t).try(&.score)
          actual = scorer.score(q.downcase, t.downcase, t)
          actual.should eq(expected), "#{q} vs #{t}: #{actual} != #{expected}"
          checked += 1
        end
      end
      checked.should be > 50
    end
  end
end
