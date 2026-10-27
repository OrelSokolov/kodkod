# kodkod — DisplayDoc: the single projection layer between the
# document (rope + tokens) and the screen. STRUCTURE (doc line ↔
# display row, fold blocks) is cheap and cached per (version, mode
# flags, reveals); MATERIALIZED rows (runs carrying BOTH content-x
# spans and doc column spans) are built for visible rows only and
# persist on the cached doc — the widget instance is rebuilt every
# frame, so state that must survive between frames (click hit-tests)
# lives here, on the buffer's cache.
#
# Painting and hit-testing go through the SAME run list, so the two
# directions cannot disagree — the v1 triple (col_x / x_at_col /
# col_at_x over a separate fragment map) is gone.

require "egui-cr/egui"
require "./fold_map"

module Kodkod
  class DisplayDoc
    # One painted run: `text` spans content-x [x0, x1) and doc
    # columns [c0, c1) (columns are line-local). A MARKER run stands
    # in for hidden text: the elision "..." carries its hidden doc
    # range (c0 < c1, hit-test snaps to the near edge); the fold
    # marker at a line end carries c0 == c1 (maps to the line end).
    record Run, text : String, x0 : Float64, x1 : Float64,
      c0 : Int32, c1 : Int32, marker : Bool

    class Row
      getter doc : Int32
      getter runs : Array(Run)
      getter width : Float64

      def initialize(@doc, @runs, @width)
      end
    end

    getter rows_count : Int32
    getter row_of : Array(Int32)  # doc line → display row (hidden: header's)
    getter line_at : Array(Int32) # display row → its doc line
    getter blocks : Array(FoldMap::Block)

    def self.identity(line_count : Int32) : DisplayDoc
      new(line_count, [] of FoldMap::Block)
    end

    def initialize(line_count : Int32, @blocks : Array(FoldMap::Block))
      @row_of = Array(Int32).new(line_count, 0)
      @line_at = [] of Int32
      # A folded block occupies ONE display row: the body AND its
      # `end` (the stop line) hide behind the header.
      hidden = Set(Int32).new
      @blocks.each do |b|
        ((b.header + 1)..b.stop).each { |l| hidden << l }
      end
      row = 0
      line_count.times do |l|
        if hidden.includes?(l)
          # Park hidden lines on the header's row — anchors and stale
          # carets written into a hidden line still measure somewhere
          # sane until the snap moves them out.
          @row_of[l] = {row - 1, 0}.max
        else
          @row_of[l] = row
          @line_at << l
          row += 1
        end
      end
      @rows_count = row
      @mat = {} of Int32 => Row # materialized rows (visible window)
      @mat_font = -1.0
    end

    def row_of_line(line : Int32) : Int32
      @row_of[line.clamp(0, {@row_of.size - 1, 0}.max)]
    end

    def line_at_row(row : Int32) : Int32
      @line_at[row.clamp(0, {@line_at.size - 1, 0}.max)]
    end

    def hidden_line?(line : Int32) : Bool
      line >= 0 && line < @row_of.size &&
        @row_of[line] < @line_at.size && @line_at[@row_of[line]] != line
    end

    # Whether `line` is a block header with a hidden tail (the
    # materializer appends the fold marker run to such a header).
    def folded_header?(line : Int32) : Bool
      @blocks.any? { |b| b.header == line && b.stop > b.header }
    end

    # The block covering `line` (header, body or the hidden stop),
    # or nil. Blocks are sorted and disjoint: the first whose stop is
    # at or past `line` is the only candidate.
    def block_near(line : Int32) : FoldMap::Block?
      if (b = @blocks.bsearch { |blk| blk.stop >= line })
        b.header <= line ? b : nil
      end
    end

    # --- materialized rows --------------------------------------------

    def row(line : Int32) : Row?
      @mat[line]?
    end

    def store_row(line : Int32, runs : Array(Run), width : Float64,
                  font_size : Float64) : Nil
      if @mat_font != font_size
        @mat.clear
        @mat_font = font_size
      end
      @mat[line] = Row.new(line, runs, width)
    end

    # --- the coordinate boundary --------------------------------------
    # doc col ↔ content-x through ONE run list (the only place the
    # two directions meet). Callers fall back to full-text prefix
    # measures when a row is not materialized (identity projection,
    # outside the last window).

    def col_at(r : Row, x : Float64, text : String,
               fonts : Egui::Fonts, font_size : Float64) : Int32
      return 0 if r.runs.empty?
      r.runs.each do |run|
        next if x >= run.x1
        if run.marker && run.c1 > run.c0
          # Elided text: snap to the hidden range's near edge.
          return x < (run.x0 + run.x1) / 2.0 ? run.c0 : run.c1
        end
        lo = run.c0
        hi = run.c1
        while lo < hi
          mid = (lo + hi + 1) // 2
          if run.x0 + fonts.measure(text[run.c0...mid], font_size).x <= x
            lo = mid
          else
            hi = mid - 1
          end
        end
        return lo
      end
      r.runs.last.c1
    end

    def x_at(r : Row, col : Int32, text : String,
             fonts : Egui::Fonts, font_size : Float64) : Float64
      return 0.0 if r.runs.empty?
      r.runs.each do |run|
        next if col > run.c1
        if col <= run.c0
          return run.x0
        elsif col == run.c1
          return run.x1 # boundary: the next run starts here
        elsif run.marker && run.c1 > run.c0
          return col - run.c0 > run.c1 - col ? run.x1 : run.x0
        else
          return run.x0 + fonts.measure(text[run.c0...col], font_size).x
        end
      end
      r.runs.last.x1
    end
  end
end
