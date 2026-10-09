# kodkod — the document model: a rope buffer (large-file editing) plus
# an edit journal (undo/redo) and a syntax-token cache keyed by buffer
# version. The widget never mutates the rope directly — every edit
# funnels through `#apply`, so the journal and the highlight cache stay
# coherent with one code path.

require "./rope"
require "./syntax"

module Kodkod
  class EditorBuffer
    property rope : Rope
    property path : String?
    property lang : String?
    property? dirty : Bool = false

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
  end
end
