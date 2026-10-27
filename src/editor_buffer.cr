# kodkod — the document model: a rope buffer (large-file editing) plus
# an edit journal (undo/redo) and a syntax-token cache keyed by buffer
# version. The widget never mutates the rope directly — every edit
# funnels through `#apply`, so the journal and the highlight cache stay
# coherent with one code path.

require "./rope"
require "./syntax"
require "./fold_map"
require "./display_doc"

module Kodkod
  class EditorBuffer
    property rope : Rope
    property path : String?
    property lang : String?
    property? dirty : Bool = false
    # The file's mtime as the app last saw it (set on open, save, and
    # reload — see KodkodApp). An fs event arriving with an unchanged
    # mtime is the app's own write, not an external change.
    property disk_mtime : Time? = nil

    # Files above this many characters skip whole-file tokenization:
    # the highlight pass is synchronous, and past half a megabyte the
    # first-frame tokenize stops being pocket change. Incremental
    # highlighting can lift this later.
    HIGHLIGHT_MAX_CHARS = 512_000

    def initialize(text : String = "", @path : String? = nil,
                   @lang : String? = nil)
      @rope = Rope.new(text)
    end

    def name : String
      (path = @path) ? File.basename(path) : "Untitled"
    end

    def text : String
      @rope.to_s
    end

    # Whether the file on disk no longer matches the app's last known
    # state — an external change to the file behind an open tab (a
    # missing file is not a change: nothing to reload from). The
    # reload prompt keys off this (see KodkodApp#on_doc_fs_event).
    def changed_on_disk? : Bool
      return false unless (path = @path) && (info = File.info?(path))
      info.modification_time != @disk_mtime
    end

    def version : Int32
      @rope.version
    end

    # --- edit journal -----------------------------------------------
    #
    # One journal entry per user-visible edit; undo reapplies the
    # inverse. No coalescing: five typed characters are five undos —
    # simple and predictable, and rope edits make each step cheap.

    record Edit, pos : Int32, inserted : String, deleted : String

    @undo_stack = [] of Edit
    @redo_stack = [] of Edit

    def apply(pos : Int32, insert : String = "", delete_count : Int32 = 0) : Nil
      pos = pos.clamp(0, @rope.size)
      delete_count = delete_count.clamp(0, @rope.size - pos)
      return if insert.empty? && delete_count.zero?
      deleted = delete_count > 0 ? @rope.slice(pos, delete_count) : ""
      @rope.delete(pos, delete_count) if delete_count > 0
      @rope.insert(pos, insert) unless insert.empty?
      @undo_stack << Edit.new(pos, insert, deleted)
      @redo_stack.clear
      @dirty = true
    end

    # Returns {edit, cursor_hint} — after an undo the caret belongs at
    # the end of the restored text; after a redo at the end of the
    # re-applied insertion.
    def undo : {Edit, Int32}?
      return nil if @undo_stack.empty?
      e = @undo_stack.pop
      @rope.delete(e.pos, e.inserted.size) unless e.inserted.empty?
      @rope.insert(e.pos, e.deleted) unless e.deleted.empty?
      @redo_stack << e
      {e, e.pos + e.deleted.size}
    end

    def redo : {Edit, Int32}?
      return nil if @redo_stack.empty?
      e = @redo_stack.pop
      @rope.delete(e.pos, e.deleted.size) unless e.deleted.empty?
      @rope.insert(e.pos, e.inserted) unless e.inserted.empty?
      @undo_stack << e
      {e, e.pos + e.inserted.size}
    end

    def undoable? : Bool
      !@undo_stack.empty?
    end

    def redoable? : Bool
      !@redo_stack.empty?
    end

    # --- syntax cache ------------------------------------------------
    #
    # Whole-file tokenization, computed lazily once per (version, lang)
    # and invalidated by any edit. `token_starts[i]` is the character
    # offset where `tokens[i]` begins — the widget binary-searches it
    # per visible line. nil when highlighting is unavailable (unknown
    # language or buffer over the size cap).

    @hl_version : Int32 = -1
    @hl_lang : String? = nil
    @tokens = [] of Syntax::Token
    @token_starts = [] of Int32

    def token_spans : {Array(Int32), Array(Syntax::Token)}?
      lang = @lang
      return nil if lang.nil? || @rope.size > HIGHLIGHT_MAX_CHARS
      if @hl_version != @rope.version || @hl_lang != lang
        tokens = Syntax.highlight(text, lang)
        return nil if tokens.nil?
        starts = Array(Int32).new(tokens.size + 1, 0)
        acc = 0
        tokens.each_with_index do |t, i|
          starts[i] = acc
          acc += t.text.size
        end
        starts[tokens.size] = acc
        @tokens = tokens
        @token_starts = starts
        @hl_version = @rope.version
        @hl_lang = lang
      end
      {@token_starts, @tokens}
    end

    # --- view modes / display projection ------------------------------
    #
    # The view-mode flags are projection INPUTS, per document like
    # `lang` — the app writes them when settings change, and every
    # consumer (the widget's render, vertical_line, goto_line's
    # reveal) sees one truth through `#display` without reaching into
    # a widget instance or a memory cell.
    property hide_annotations : Bool = false
    property hide_blocks : Bool = false

    # Foldable blocks (FoldMap.scan_blocks), computed once per
    # (version, lang) like the token cache. `reveal_line` unfolds the
    # blocks covering a jump target (search, :123, symbol browser) —
    # reveals live on the buffer (the widget is rebuilt every frame)
    # and reset on any edit: line indexes shift under them.

    @fb_version : Int32 = -1
    @fb_lang : String? = nil
    @fb_blocks = [] of FoldMap::Block
    @revealed = Set(Int32).new # headers of jump-unfolded blocks
    @reveal_gen = 0

    # THE projection: structure cached by (version, mode flags,
    # reveals); materialized rows live inside it (see DisplayDoc).
    @dd_key : {Int32, Bool, Bool, Int32} = {-1, false, false, -1}
    @dd : DisplayDoc = DisplayDoc.identity(0)

    def fold_blocks : Array(FoldMap::Block)
      if @fb_version != @rope.version || @fb_lang != @lang
        @fb_blocks = FoldMap.scan_blocks(@rope, @lang)
        @fb_version = @rope.version
        @fb_lang = @lang
        @revealed.clear
        @reveal_gen += 1
      end
      @fb_blocks
    end

    # Unfold every block whose hidden range contains `line` — the
    # hidden range is (header, stop]: the body AND the `end` line.
    def reveal_line(line : Int32) : Nil
      fold_blocks.each do |b|
        if line > b.header && line <= b.stop && @revealed.add?(b.header)
          @reveal_gen += 1
        end
      end
    end

    def display : DisplayDoc
      # fold_blocks FIRST: the very first call bumps @reveal_gen
      # (cache reset), and a key computed before that would mismatch
      # the freshly built doc — the cache (with its materialized
      # rows) then dropped on the very next access.
      blocks = @revealed.empty? ? fold_blocks :
                 fold_blocks.reject { |b| @revealed.includes?(b.header) }
      key = {@rope.version, @hide_blocks, @hide_annotations, @reveal_gen}
      return @dd if @dd_key == key
      @dd = @hide_blocks ?
        DisplayDoc.new(@rope.line_count, blocks) :
        DisplayDoc.identity(@rope.line_count)
      @dd_key = key
      @dd
    end
  end
end
