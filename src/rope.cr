# kodkod's text buffer: a rope — a balanced binary tree whose leaves
# hold flat String chunks. Opening a 20+ MB file must not freeze a
# frame, so edits and line queries touch only O(log n) nodes plus one
# ~1 KiB leaf, and the whole text is flattened (`to_s`) only for rare
# whole-buffer consumers (save, search).
#
# ALL offsets and lengths are CHARACTER indexes/counts — Crystal's
# String#[]/.size count chars, not bytes (same convention as egui's
# TextArea caret/selection), and leaves are only ever cut at char
# boundaries, so UTF-8 never splits mid-glyph.
#
# Nodes cache their subtree's char weight and newline count, making
# every line query (line_of/line_start/line_text/...) a single
# root-to-leaf walk; a leaf additionally caches the char offsets of
# its newlines, built lazily once — leaves are immutable after
# creation, so the cache never goes stale.
#
# Edits split the tree at the offset, splice leaves in (or cut them
# out) and re-join: a handful of fresh nodes per edit, no O(n) work.
# That grows depth and fragments leaves over time, so after
# REBUILD_EVERY edits (or when depth passes MAX_DEPTH) the tree is
# rebuilt balanced from its leaves, merging undersized neighbours —
# simple, correct, amortized cheap.

module Kodkod
  class Rope
    # Leaves hold at most this many characters: small enough that a
    # leaf scan (newline index, substring) is pocket change, large
    # enough that a multi-megabyte file is a few thousand nodes.
    LEAF_MAX = 1024

    # Rebuild the tree balanced when depth passes this (each edit adds
    # ~2 levels) or after this many edits (leaf fragmentation).
    MAX_DEPTH      = 40
    REBUILD_EVERY  = 64

    # A tree node: a leaf (text set, children nil) or an internal node.
    # Besides the children it caches exactly what the line queries
    # need on the way down — char weight, newline count, depth — so
    # no query ever re-walks a subtree. Immutable once built; edits
    # construct fresh nodes along the changed path only.
    class Node
      property text : String?
      property left : Node?
      property right : Node?
      property weight : Int32
      property newlines : Int32
      property depth : Int32
      # Char offsets of '\n' within this leaf — built on first use.
      property newline_offsets : Array(Int32)?

      def initialize(@text : String)
        @left = nil
        @right = nil
        @weight = text.size
        newlines = 0
        text.each_byte { |b| newlines += 1 if b == 0x0A }
        @newlines = newlines
        @depth = 1
      end

      def initialize(@left : Node, @right : Node)
        @text = nil
        @weight = left.weight + right.weight
        @newlines = left.newlines + right.newlines
        @depth = {left.depth, right.depth}.max + 1
      end

      # Char offsets of the newlines in this leaf, lazily indexed.
      def nl_offsets : Array(Int32)
        (c = @newline_offsets) || begin
          offs = [] of Int32
          i = 0
          @text.not_nil!.each_char do |ch|
            offs << i if ch == '\n'
            i += 1
          end
          @newline_offsets = offs
        end
      end
    end

    @root : Node
    @version : Int32 = 0
    @edit_count : Int32 = 0
    @edits_since_rebuild : Int32 = 0

    def initialize(text : String = "")
      chunks = Rope.chunk(text)
      @root = Rope.build(chunks, 0, chunks.size)
    end

    def size : Int32
      @root.weight
    end

    # Full flattening — O(n); only for rare whole-buffer consumers.
    def to_s : String
      String.build do |io|
        dump(@root, io)
      end
    end

    # Bumped by 1 on every insert/delete call so caches elsewhere
    # (highlights, layout) can invalidate on a cheap version compare.
    def version : Int32
      @version
    end

    # Number of insert/delete calls since construction (tests use it
    # to confirm a fuzzer really edited).
    def edit_count : Int32
      @edit_count
    end

    def insert(at : Int32, text : String) : Nil
      at = at.clamp(0, size)
      @version += 1
      @edit_count += 1
      return if text.empty?
      left, right = split(@root, at)
      chunks = Rope.chunk(text)
      mid = Rope.build(chunks, 0, chunks.size)
      @root = join(join(left, mid), right) || Node.new("")
      maybe_rebalance
    end

    def delete(from : Int32, count : Int32) : Nil
      from = from.clamp(0, size)
      count = count.clamp(0, size - from)
      @version += 1
      @edit_count += 1
      return if count == 0
      left, rest = split(@root, from)
      right = nil
      if r = rest
        _, right = split(r, count)
      end
      @root = join(left, right) || Node.new("")
      maybe_rebalance
    end

    # Char at character index i. Out of range is a caller bug, not
    # something to clamp, so it raises.
    def char_at(i : Int32) : Char
      raise IndexError.new("Rope#char_at(#{i}) with size #{size}") unless 0 <= i < size
      char_at_in(@root, i)
    end

    def slice(from : Int32, count : Int32) : String
      from = from.clamp(0, size)
      count = count.clamp(0, size - from)
      return "" if count == 0
      String.build do |io|
        slice_into(@root, from, count, io)
      end
    end

    # Line count; "a\nb" = 2, "a\n" = 2 (a trailing newline opens a
    # phantom last line), "" = 1.
    def line_count : Int32
      @root.newlines + 1
    end

    # Char offset where line `line` starts; valid for 0..line_count-1
    # (line 0 is always 0), clamped otherwise.
    def line_start(line : Int32) : Int32
      line = line.clamp(0, line_count - 1)
      return 0 if line == 0
      after_newline(@root, line)
    end

    # Line index containing char offset `offset` — an offset at a line
    # start belongs to that line; offset == size is the caret position
    # at the very end (the phantom line after a trailing newline).
    def line_of(offset : Int32) : Int32
      offset = offset.clamp(0, size)
      newlines_before(@root, offset)
    end

    # The line's text WITHOUT the trailing '\n'.
    def line_text(line : Int32) : String
      line = line.clamp(0, line_count - 1)
      s = line_start(line)
      slice(s, chars_to_newline(@root, s))
    end

    # Chars in the line, '\n' not included.
    def line_length(line : Int32) : Int32
      line = line.clamp(0, line_count - 1)
      chars_to_newline(@root, line_start(line))
    end

    def line_col_of(offset : Int32) : {Int32, Int32}
      offset = offset.clamp(0, size)
      line = newlines_before(@root, offset)
      {line, offset - line_start(line)}
    end

    def offset_at(line : Int32, col : Int32) : Int32
      line = line.clamp(0, line_count - 1)
      s = line_start(line)
      s + col.clamp(0, chars_to_newline(@root, s))
    end

    # ---- tree construction --------------------------------------------

    # Split text into leaf chunks of at most LEAF_MAX chars, cutting
    # at char boundaries only. One byte pass counting UTF-8 lead
    # bytes — repeatedly slicing by char index would rescan from the
    # start and go quadratic on megabyte inputs.
    def self.chunk(text : String) : Array(String)
      return [text] if text.size <= LEAF_MAX
      chunks = [] of String
      bytes = text.to_unsafe
      total = text.bytesize
      chars = 0
      start = 0
      i = 0
      while i < total
        if bytes[i] & 0xC0 != 0x80 # UTF-8 lead byte: a char starts here
          if chars == LEAF_MAX
            chunks << text.byte_slice(start, i - start)
            start = i
            chars = 0
          end
          chars += 1
        end
        i += 1
      end
      chunks << text.byte_slice(start, total - start)
      chunks
    end

    # Balanced tree over chunks[lo, hi) — the shape `initialize` and
    # `rebuild!` produce, depth ~log2(#leaves).
    def self.build(chunks : Array(String), lo : Int32, hi : Int32) : Node
      return Node.new(chunks[lo]) if hi - lo == 1
      mid = (lo + hi) // 2
      Node.new(build(chunks, lo, mid), build(chunks, mid, hi))
    end

    private def join(a : Node?, b : Node?) : Node?
      return b if a.nil?
      return a if b.nil?
      Node.new(a, b)
    end

    # Split a subtree at char offset `at` (0..weight) into the chars
    # before and after; sides that become empty are nil. Functional —
    # untouched subtrees are shared, only the path to the split leaf
    # is rebuilt.
    private def split(node : Node, at : Int32) : {Node?, Node?}
      return {nil, nil} if node.weight == 0
      return {nil, node} if at <= 0
      return {node, nil} if at >= node.weight
      if t = node.text
        {Node.new(t[0, at]), Node.new(t[at..])}
      else
        l = node.left.not_nil!
        r = node.right.not_nil!
        if at < l.weight
          a, b = split(l, at)
          {a, join(b, r)}
        elsif at > l.weight
          a, b = split(r, at - l.weight)
          {join(l, a), b}
        else
          {l, r}
        end
      end
    end

    private def maybe_rebalance : Nil
      @edits_since_rebuild += 1
      rebuild! if @root.depth > MAX_DEPTH || @edits_since_rebuild >= REBUILD_EVERY
    end

    # Collect the leaves, merge undersized neighbours, rebuild
    # balanced (same shape as `initialize`). Full leaves pass through
    # uncopied, so this is O(#leaves) plus the merged chars.
    private def rebuild! : Nil
      chunks = [] of String
      gather(@root, chunks)
      merged = [] of String
      acc = ""
      chunks.each do |c|
        if acc.empty?
          acc = c
        elsif acc.size + c.size <= LEAF_MAX
          acc = acc + c
        else
          merged << acc
          acc = c
        end
      end
      merged << acc unless acc.empty?
      @root = merged.empty? ? Node.new("") : Rope.build(merged, 0, merged.size)
      @edits_since_rebuild = 0
    end

    private def gather(node : Node, chunks : Array(String)) : Nil
      if t = node.text
        chunks << t unless t.empty?
      else
        gather(node.left.not_nil!, chunks)
        gather(node.right.not_nil!, chunks)
      end
    end

    # ---- queries -------------------------------------------------------

    private def dump(node : Node, io) : Nil
      if t = node.text
        io << t
      else
        dump(node.left.not_nil!, io)
        dump(node.right.not_nil!, io)
      end
    end

    private def char_at_in(node : Node, i : Int32) : Char
      if t = node.text
        t[i]
      elsif i < (l = node.left.not_nil!).weight
        char_at_in(l, i)
      else
        char_at_in(node.right.not_nil!, i - l.weight)
      end
    end

    private def slice_into(node : Node, from : Int32, count : Int32, io) : Nil
      return if count <= 0 || from >= node.weight
      if t = node.text
        io << t[from, count] # String#[] clamps count to the leaf end
      else
        l = node.left.not_nil!
        if from < l.weight
          slice_into(l, from, count, io)
          rest = count - (l.weight - from)
          slice_into(node.right.not_nil!, 0, rest, io) if rest > 0
        else
          slice_into(node.right.not_nil!, from - l.weight, count, io)
        end
      end
    end

    # Char offset just past the n-th (1-based) newline of the subtree.
    private def after_newline(node : Node, n : Int32) : Int32
      if node.text
        offs = node.nl_offsets
        n <= offs.size ? offs[n - 1] + 1 : node.weight
      elsif n <= (l = node.left.not_nil!).newlines
        after_newline(l, n)
      else
        l.weight + after_newline(node.right.not_nil!, n - l.newlines)
      end
    end

    # Newlines strictly before char offset `offset`.
    private def newlines_before(node : Node, offset : Int32) : Int32
      if node.text
        node.nl_offsets.count { |o| o < offset }
      elsif offset < (l = node.left.not_nil!).weight
        newlines_before(l, offset)
      else
        l.newlines + newlines_before(node.right.not_nil!, offset - l.weight)
      end
    end

    # Chars from `offset` to the next '\n' (or the end of the buffer).
    # When the left subtree holds no further newline, the walk has to
    # continue into the right one — a newline may sit on the seam.
    private def chars_to_newline(node : Node, offset : Int32) : Int32
      if node.text
        node.nl_offsets.each do |o|
          return o - offset if o >= offset
        end
        node.weight - offset
      elsif offset < (l = node.left.not_nil!).weight
        span = l.weight - offset
        d = chars_to_newline(l, offset)
        d < span ? d : span + chars_to_newline(node.right.not_nil!, 0)
      else
        chars_to_newline(node.right.not_nil!, offset - l.weight)
      end
    end
  end
end
