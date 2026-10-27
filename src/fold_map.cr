# kodkod — FoldMap: the block SCANNER (structure mapping lives in
# DisplayDoc). A Block is one foldable region: `header` is the
# def/class/... signature line, `stop` is its `end` line; the hidden
# range is (header, stop] — the body and the `end` both collapse
# behind the header into ONE display row.
#
# Indent-based, keyword-gated (Crystal/Ruby): a header line starts a
# block when its first word is def/class/module/struct/enum/lib (or
# the line ends in `do [|...|]`); the body runs while lines stay
# deeper-indented (blank lines count as body), and the block ends at
# the first non-blank line back at or above the header's indent —
# the `end` line. Works without tokens, so it applies to files over
# the highlight size cap too.

require "./rope"

module Kodkod
  module FoldMap
    record Block, header : Int32, stop : Int32

    HEADER_WORDS = {"def", "class", "module", "struct", "enum", "lib"}
    DO_TAIL      = /\bdo\s*(\|[^|]*\|)?\s*(#.*)?\z/

    def self.scan_blocks(rope : Rope, lang : String?) : Array(Block)
      return [] of Block unless lang.in?("crystal", "ruby")
      blocks = [] of Block
      n = rope.line_count
      indents = Array(Int32).new(n, 0)
      blanks = Array(Bool).new(n, false)
      n.times do |i|
        text = rope.line_text(i)
        blanks[i] = text.blank?
        indents[i] = indent_of(text)
      end
      i = 0
      while i < n
        unless blanks[i]
          if header?(rope.line_text(i))
            ind = indents[i]
            j = i + 1
            while j < n && blanks[j]
              j += 1
            end
            if j < n && indents[j] > ind
              # Body runs until the first non-blank line back at or
              # above the header's indent.
              stop = j
              while stop < n && (blanks[stop] || indents[stop] > ind)
                stop += 1
              end
              # Trailing blank lines before the stop stay visible —
              # the fold must not eat the gap separating the `end`
              # from what follows it.
              while stop > j + 1 && blanks[stop - 1]
                stop -= 1
              end
              blocks << Block.new(i, stop) if stop > i + 1
              i = stop - 1
            end
          end
        end
        i += 1
      end
      blocks
    end

    private def self.indent_of(text : String) : Int32
      col = 0
      text.each_char do |c|
        case c
        when ' ' then col += 1
        when '\t' then col += 8 - (col % 8)
        else break
        end
      end
      col
    end

    private def self.header?(text : String) : Bool
      stripped = text.lstrip
      word = stripped[/\A[a-z_][A-Za-z0-9_]*[?!]?/]? || ""
      return true if HEADER_WORDS.includes?(word)
      DO_TAIL.matches?(stripped)
    end
  end
end
