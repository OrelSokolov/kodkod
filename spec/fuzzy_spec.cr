require "spec"
require "../src/fuzzy"

# Verifies the fuzzy matcher (ported from hcode's finder): subsequence
# requirement, scoring/ranking quality, match-position reconstruction.
describe Kodkod::Fuzzy do
  describe ".matches?" do
    it "matches a subsequence case-insensitively" do
      Kodkod::Fuzzy.matches?("g45", "glm-4.5").should be_true
      Kodkod::Fuzzy.matches?("G45", "glm-4.5").should be_true
    end

    it "rejects when chars are out of order or missing" do
      Kodkod::Fuzzy.matches?("54", "glm-4.5").should be_false
      Kodkod::Fuzzy.matches?("abc", "ab").should be_false
    end

    it "treats empty query as non-matching" do
      Kodkod::Fuzzy.matches?("", "anything").should be_false
    end
  end

  describe ".match (score + positions)" do
    it "returns matched positions in ascending order" do
      res = Kodkod::Fuzzy.match("g45", "glm-4.5")
      res.should_not be_nil
      res = res || raise "res should not be nil"
      res.positions.should eq([0, 4, 6])
      res.score.should be > 0
    end

    it "scores a prefix/word-boundary match higher than a scattered one" do
      prefix = (Kodkod::Fuzzy.match("glm", "glm-4.5") || raise "match failed").score
      scattered = (Kodkod::Fuzzy.match("glm", "x-g-l-m") || raise "match failed").score
      prefix.should be > scattered
    end

    it "scores consecutive matches higher than gapped ones" do
      tight = (Kodkod::Fuzzy.match("air", "glm-4.5-air") || raise "match failed").score
      gapped = (Kodkod::Fuzzy.match("air", "a___i___r") || raise "match failed").score
      tight.should be > gapped
    end

    it "rewards camelCase boundary matches" do
      camel = (Kodkod::Fuzzy.match("gf", "glmFour") || raise "match failed").score
      plain = (Kodkod::Fuzzy.match("gf", "glmfour") || raise "match failed").score
      camel.should be > plain
    end

    it "returns nil when not a subsequence" do
      Kodkod::Fuzzy.match("xyz", "glm-4.5").should be_nil
      # The poison trap: a and r ARE in the text but i is not — the
      # dead diagonal must not leak BONUS_CONSECUTIVE into the sentinel.
      Kodkod::Fuzzy.match("air", "src/app.cr").should be_nil
    end
  end

  describe ".filter (ranking)" do
    it "keeps only matching items, best score first, stable on ties" do
      items = ["glm-4.5", "glm-5.2", "gpt-4o", "glm-4.5-air"]
      ranked = Kodkod::Fuzzy.filter(items, "glm")
      # All three glm-* have 'glm' at the same leading positions, so their
      # scores tie and input order is preserved; gpt-4o is filtered out.
      ranked.map(&.[0]).should eq([0, 1, 3])
    end

    it "ranks a word-boundary match above a scattered one" do
      items = ["xglm", "glm-4.5"]
      ranked = Kodkod::Fuzzy.filter(items, "glm")
      ranked.map(&.[0]).should eq([1, 0])
    end

    it "returns empty for a query matching nothing" do
      items = ["glm-4.5", "glm-5.2"]
      Kodkod::Fuzzy.filter(items, "zzz").should be_empty
    end
  end
end
