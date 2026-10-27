require "spec"
require "../src/fold_map"
require "../src/display_doc"

describe Kodkod::FoldMap do
  it "scans an outer block whole (nested defs swallowed)" do
    code = <<-CRYSTAL
      class Foo
        def bar
          1
        end

        def baz
          2
        end
      end

      top = 1
      CRYSTAL
    rope = Kodkod::Rope.new(code)
    blocks = Kodkod::FoldMap.scan_blocks(rope, "crystal")
    blocks.size.should eq(1)
    b = blocks.first
    b.header.should eq(0)
    # stop = the class's `end` line — hidden is (0, 8]: body + end.
    b.stop.should eq(8)
  end

  it "folds a lone def and keeps the trailing gap visible" do
    code = <<-CRYSTAL
      def bar
        1
      end

      top = 1
      CRYSTAL
    rope = Kodkod::Rope.new(code)
    blocks = Kodkod::FoldMap.scan_blocks(rope, "crystal")
    blocks.size.should eq(1)
    blocks.first.header.should eq(0)
    blocks.first.stop.should eq(2) # hides line 1; line 2 is the `end`
  end

  it "leaves one-liner defs and non-block lines alone" do
    code = <<-CRYSTAL
      def bar; 1; end
      x = [1, 2].map { |v| v }
      top = 1
      CRYSTAL
    rope = Kodkod::Rope.new(code)
    Kodkod::FoldMap.scan_blocks(rope, "crystal").should be_empty
  end

  it "returns no blocks for unknown languages" do
    rope = Kodkod::Rope.new("def foo\n  1\nend\n")
    Kodkod::FoldMap.scan_blocks(rope, "c").should be_empty
    Kodkod::FoldMap.scan_blocks(rope, nil).should be_empty
  end
end

describe Kodkod::DisplayDoc do
  it "collapses a block to ONE row (body and `end` hidden)" do
    code = <<-CRYSTAL
      def bar
        1
      end

      top = 1
      CRYSTAL
    rope = Kodkod::Rope.new(code)
    disp = Kodkod::DisplayDoc.new(rope.line_count,
      Kodkod::FoldMap.scan_blocks(rope, "crystal"))
    # Rows: header, blank, top — the body AND the `end` are gone.
    disp.rows_count.should eq(3)
    disp.row_of_line(0).should eq(0)
    disp.row_of_line(1).should eq(0) # hidden: parked on the header
    disp.row_of_line(2).should eq(0) # the `end` hides too
    disp.row_of_line(3).should eq(1)
    disp.line_at_row(0).should eq(0)
    disp.line_at_row(1).should eq(3)
    disp.line_at_row(2).should eq(4)
    disp.hidden_line?(1).should be_true
    disp.hidden_line?(2).should be_true # the `end` line
    disp.hidden_line?(0).should be_false
    disp.hidden_line?(3).should be_false
    disp.folded_header?(0).should be_true
    disp.folded_header?(2).should be_false # hidden: not a row
    disp.block_near(2).should eq(Kodkod::FoldMap::Block.new(0, 2))
  end

  it "identity maps rows to lines unchanged" do
    disp = Kodkod::DisplayDoc.identity(5)
    disp.rows_count.should eq(5)
    disp.row_of_line(3).should eq(3)
    disp.line_at_row(4).should eq(4)
    disp.hidden_line?(2).should be_false
    disp.folded_header?(0).should be_false
  end
end
