require "spec"
require "../src/rope"

# Fuzz oracle: a plain String plus its line-start offsets, maintained
# incrementally so 10k ops on a growing buffer stay quick (recomputing
# line starts from the string every op would dominate the test time).
class RopeModel
  property text : String
  property starts : Array(Int32)

  def initialize(@text)
    @starts = RopeModel.line_starts(@text)
  end

  # Char offset of every line start; size = line count ("a\n" = 2).
  def self.line_starts(text : String) : Array(Int32)
    starts = [0]
    chars = 0
    text.each_char do |ch|
      chars += 1
      starts << chars if ch == '\n'
    end
    starts
  end

  def line_count : Int32
    @starts.size
  end

  def insert(at : Int32, s : String) : Nil
    at = at.clamp(0, @text.size)
    # Starts strictly past `at` shift; a start AT `at` stays — the
    # inserted text's first char takes that line over in place.
    starts = @starts.map { |st| st > at ? st + s.size : st }
    chars = 0
    s.each_char do |ch|
      chars += 1
      starts << at + chars if ch == '\n'
    end
    starts.sort!
    @text = @text[0, at] + s + @text[at..]
    @starts = starts
  end

  def delete(from : Int32, count : Int32) : Nil
    from = from.clamp(0, @text.size)
    count = count.clamp(0, @text.size - from)
    return if count == 0
    hi = from + count
    starts = @starts.reject { |st| st > from && st <= hi }
    starts.map! { |st| st > hi ? st - count : st }
    @text = @text[0, from] + @text[hi..]
    @starts = starts
  end

  # Greatest line index whose start is <= offset (a line start belongs
  # to its own line).
  def line_of(offset : Int32) : Int32
    lo = 0
    hi = @starts.size - 1
    ans = 0
    while lo <= hi
      mid = (lo + hi) // 2
      if @starts[mid] <= offset
        ans = mid
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    ans
  end

  def line_text(line : Int32) : String
    s = @starts[line]
    e = line + 1 < @starts.size ? @starts[line + 1] - 1 : @text.size
    @text[s, e - s]
  end
end

# Seeded random text: short pieces with newlines and multi-byte UTF-8,
# in the shapes an editor buffer actually sees.
module RopeSpecText
  PIECES = ["a", "b", "code", " ", "  ", "\n", "\n\n", "é", "ü", "ß", "я",
            "ж", "🎉", "Σ", "Ω", "→", "hello world ", "x" * 60, "line\n",
            "if (x)\n", "\t"]

  def self.piece(rng : Random) : String
    String.build do |io|
      rng.rand(10).times { io << PIECES[rng.rand(PIECES.size)] }
    end
  end

  def self.random(rng : Random, chars : Int32) : String
    n = 0
    String.build do |io|
      while n < chars
        s = PIECES[rng.rand(PIECES.size)]
        io << s
        n += s.size
      end
    end
  end
end

describe Kodkod::Rope do
  describe "golden" do
    it "empty rope" do
      r = Kodkod::Rope.new
      r.size.should eq 0
      r.to_s.should eq ""
      r.line_count.should eq 1
      r.line_text(0).should eq ""
      r.line_start(0).should eq 0
      r.line_of(0).should eq 0
      r.line_length(0).should eq 0
      r.line_col_of(0).should eq({0, 0})
      r.offset_at(0, 0).should eq 0
      r.offset_at(9, 9).should eq 0 # clamped
      r.version.should eq 0
      r.edit_count.should eq 0
    end

    it "single line" do
      r = Kodkod::Rope.new("hello world")
      r.size.should eq 11
      r.line_count.should eq 1
      r.line_text(0).should eq "hello world"
      r.line_length(0).should eq 11
      r.line_start(0).should eq 0
      r.line_start(7).should eq 0 # clamped to the only line
      r.line_of(11).should eq 0
      r.line_of(999).should eq 0  # clamped
      r.char_at(0).should eq 'h'
      r.char_at(10).should eq 'd'
      expect_raises(IndexError) { r.char_at(11) }
    end

    it "\"a\\nb\\nc\" — three lines, no trailing newline" do
      r = Kodkod::Rope.new("a\nb\nc")
      r.size.should eq 5
      r.line_count.should eq 3
      r.line_start(0).should eq 0
      r.line_start(1).should eq 2
      r.line_start(2).should eq 4
      r.line_text(0).should eq "a"
      r.line_text(1).should eq "b"
      r.line_text(2).should eq "c"
      r.line_length(1).should eq 1
      {0, 1, 2, 3, 4, 5}.each do |off|
        r.line_of(off).should eq RopeModel.new("a\nb\nc").line_of(off)
      end
      r.line_col_of(3).should eq({1, 1})
      r.offset_at(1, 0).should eq 2
      r.offset_at(1, 1).should eq 3
      r.offset_at(1, 99).should eq 3 # col clamped to line end
      r.slice(1, 3).should eq "\nb\n"
    end

    it "trailing newline opens a phantom line" do
      r = Kodkod::Rope.new("a\nb\n")
      r.size.should eq 4
      r.line_count.should eq 3
      r.line_text(2).should eq ""
      r.line_length(2).should eq 0
      r.line_start(2).should eq 4
      r.line_of(4).should eq 2
      r.line_col_of(4).should eq({2, 0})
      r.offset_at(2, 0).should eq 4
    end

    it "UTF-8: char offsets, not bytes" do
      text = "héllo\nмир\n🎉\n"
      r = Kodkod::Rope.new(text)
      r.size.should eq 12 # 5+1+3+1+1+1 chars, not bytes
      r.line_count.should eq 4
      r.char_at(1).should eq 'é'
      r.char_at(6).should eq 'м'
      r.char_at(10).should eq '🎉'
      r.line_start(1).should eq 6
      r.line_start(2).should eq 10
      r.line_start(3).should eq 12
      r.line_text(0).should eq "héllo"
      r.line_text(1).should eq "мир"
      r.line_text(2).should eq "🎉"
      r.line_text(3).should eq ""
      r.line_of(9).should eq 1 # the '\n' of "мир"
    end

    it "UTF-8: line_col_of on a multi-byte char" do
      r = Kodkod::Rope.new("héllo\nмир\n🎉\n")
      # offset 11 is the '\n' closing the "🎉" line (line 2, col 1)
      r.line_col_of(11).should eq({2, 1})
      r.line_col_of(10).should eq({2, 0})
    end

    it "UTF-8: chunking, insert and delete never split a glyph" do
      text = "é𝔘x" * 800 # 2400 chars, ~6 KB — spans several leaves
      r = Kodkod::Rope.new(text)
      r.size.should eq text.size
      r.to_s.should eq text
      mid = text.size // 2
      r.insert(mid, "🎉мир")
      r.to_s.should eq text[0, mid] + "🎉мир" + text[mid..]
      r.delete(mid, "🎉мир".size) # exactly the inserted chars
      r.to_s.should eq text
      r.char_at(mid).should eq text[mid]
    end

    it "line_start/line_of/offset_at roundtrip for every offset" do
      text = "ab\ncédé\n\nxyz🎉\nq"
      starts = RopeModel.line_starts(text)
      model = RopeModel.new(text)
      r = Kodkod::Rope.new(text)
      (0..text.size).each do |off|
        line = model.line_of(off)
        col = off - starts[line]
        r.line_of(off).should eq line
        r.line_col_of(off).should eq({line, col})
        r.offset_at(line, col).should eq off
      end
      r.line_of(10_000).should eq model.line_of(text.size) # clamped
      r.line_start(99).should eq starts.last               # clamped
    end

    it "insert at boundaries 0 and size; version and edit_count" do
      r = Kodkod::Rope.new
      r.insert(0, "ab")      # into empty
      r.to_s.should eq "ab"
      r.insert(2, "cd")      # at size (append)
      r.to_s.should eq "abcd"
      r.insert(0, "xy")      # at 0 (prepend)
      r.to_s.should eq "xyabcd"
      r.insert(-5, "Z")      # clamps to 0
      r.to_s.should eq "Zxyabcd"
      r.insert(999, "!")     # clamps to size
      r.to_s.should eq "Zxyabcd!"
      r.version.should eq 5
      r.edit_count.should eq 5
      r.size.should eq 8
    end

    it "delete across leaf boundaries" do
      text = "The quick brown fox jumps\n" * 400 # 10_400 chars, ~11 leaves
      r = Kodkod::Rope.new(text)
      r.size.should eq text.size
      r.delete(1_000, 6_000)
      expected = text[0, 1_000] + text[7_000..]
      r.to_s.should eq expected
      model = RopeModel.new(expected)
      r.line_count.should eq model.line_count
      model.line_count.times do |line|
        r.line_start(line).should eq model.starts[line]
        r.line_text(line).should eq model.line_text(line)
      end
    end

    it "delete past the end clamps" do
      r = Kodkod::Rope.new("abc\ndef")
      r.delete(4, 999) # clamps count to size - from
      r.to_s.should eq "abc\n"
      r.delete(0, 0) # no-op
      r.to_s.should eq "abc\n"
      r.delete(-3, 2) # from clamps to 0
      r.to_s.should eq "c\n"
      r.delete(999, 5) # from clamps to size → nothing left to delete
      r.to_s.should eq "c\n"
      r.size.should eq 2
    end
  end

  describe "fuzz vs plain String model" do
    it "matches over 10_000 seeded random ops" do
      rng = Random.new(42)
      base = RopeSpecText.random(rng, 16_000)
      rope = Kodkod::Rope.new(base)
      model = RopeModel.new(base)
      10_000.times do |i|
        # Size governor: keep the buffer around ~10 KB so the String
        # model's O(n) edits don't dominate the run time; the op mix
        # stays seeded-random otherwise (cumulative churn is well past
        # 100k chars either way).
        n = model.text.size
        pick = n > 14_000 ? 100 : (n < 6_000 ? 0 : rng.rand(100))
        if pick < 55
          at = rng.rand(model.text.size + 1)
          s = rng.rand(40) == 0 ? RopeSpecText.random(rng, 120) : RopeSpecText.piece(rng)
          rope.insert(at, s)
          model.insert(at, s)
        else
          from = rng.rand(model.text.size + 1)
          count = rng.rand(24)
          rope.delete(from, count)
          model.delete(from, count)
        end

        rope.size.should eq model.text.size
        rope.line_count.should eq model.line_count
        rope.to_s.should eq model.text

        if (n = model.text.size) > 0
          off = rng.rand(n + 1)
          line = model.line_of(off)
          col = off - model.starts[line]
          rope.line_of(off).should eq line
          rope.line_col_of(off).should eq({line, col})
          rope.offset_at(line, col).should eq off

          line2 = rng.rand(model.line_count)
          rope.line_start(line2).should eq model.starts[line2]
          rope.line_text(line2).should eq model.line_text(line2)
          rope.line_length(line2).should eq model.line_text(line2).size

          from = rng.rand(n + 1)
          count = rng.rand({n - from, 96}.min + 1)
          rope.slice(from, count).should eq model.text[from, count]

          ci = rng.rand(n)
          rope.char_at(ci).should eq model.text[ci]
        else
          rope.line_of(5).should eq 0 # clamped on an empty buffer
        end

        # The model itself is only trusted if its incremental line
        # starts still match a full recompute.
        if i % 1000 == 999
          model.starts.should eq RopeModel.line_starts(model.text)
        end
      end
      rope.edit_count.should eq 10_000
    end
  end

  describe "perf smoke" do
    it "1000 middle inserts into a 1M-char rope finish in seconds" do
      line = "x" * 79 + "\n" # 80 chars
      text = line * 12_500
      text.size.should eq 1_000_000
      rope = Kodkod::Rope.new(text)
      rope.size.should eq 1_000_000
      rope.line_count.should eq 12_501

      t0 = Time.instant
      1_000.times { |i| rope.insert(rope.size // 2, "insert #{i}\n") }
      dt = Time.instant - t0

      dt.total_seconds.should be < 5.0
      inserted = (0...1_000).sum { |i| "insert #{i}\n".size }
      rope.size.should eq 1_000_000 + inserted
      rope.line_count.should eq 13_501 # each insert opened one line
      rope.to_s.size.should eq rope.size
      rope.line_text(0).should eq "x" * 79
      rope.line_of(500_000).should be > 6_000 # mid-buffer query still cheap
    end
  end
end
