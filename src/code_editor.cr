# kodkod — CodeEditor: a line-oriented code editing widget on a rope.
#
# TextArea is shaped like an HTML <textarea> (soft wrap, whole-buffer
# String layout, caret state hidden inside); a code editor wants the
# opposite: no wrap, a line-number gutter, syntax-colored runs and a
# PUBLIC cursor/selection API (the VIM layer drives the caret through
# it). The buffer is a Kodkod::Rope — only the visible window of lines
# is ever laid out, so a 20 MB file paints for the viewport's price.
#
# Line geometry is MEASURED, not grid-math: a column boundary is
# `fonts.measure(prefix)` on the monospace stack — the same advances
# the backend rasterizes, so the caret/selection sit exactly on the
# glyphs even when they fall back to a non-mono face (Cyrillic, CJK)
# or the face's advance differs from `char_w` (the estimated advance
# of "M", kept only for the gutter width, wheel speed and margins —
# a col*char_w grid would drift more the longer the line). One line =
# `line_h` pixels; rows are built directly (no Fonts#layout pass) with
# runs pre-colored by the syntax palette.
#
# State lives in Memory cells under a GLOBAL id derived from focus_id
# (Id.from("kodkod/code_editor/#{focus_id}")), not the ui scope, so
# the class-level API (cursor/selection/edits) reaches the same cells
# from anywhere — the VIM layer and the status bar never see the Ui.

require "./editor_buffer"

module Kodkod
  class CodeEditor
    include Egui::Widget

    ANCHOR_SALT  = 0x5EED_u64 # selection anchor char offset (-1 = none)
    COL_SALT     = 0x0C01_u64 # desired column (sticky up/down column)
    SEEN_SALT    = 0x5E2A_u64 # caret offset as last RENDERED (see below)
    SCROLL_SALT  = 0x5C40_u64 # scroll offset vec2 (x = horizontal)
    VEL_SALT     =  0x7E1_u64 # kinetic velocity
    BAR_SALT     = 0xBA2_u64  # vertical scrollbar grab
    HBAR_SALT    = 0xBA3_u64  # horizontal scrollbar grab
    LINE_H_SALT  = 0x11E1_u64 # line height metric (for the class API)
    VIEW_H_SALT  = 0x21EF_u64 # viewport height metric
    WMAX_SALT    = 0x3A3A_u64 # running max line width
    WMAXV_SALT   = 0x3A3B_u64 # buffer version the max was computed at
    FONT_SALT    = 0xF017_u64 # Ctrl +/- font zoom override (shared)
    BAR_W        =        8.0
    HBAR_H       =        6.0
    GUTTER_PAD   =       10.0
    # Left padding of the code text: glyphs start clear of the gutter
    # separator line instead of touching it. 8px — visible breathing
    # room (2px read as nothing next to the 1px line).
    TEXT_PAD     =        8.0
    # Context rows kept above (and below) the caret when the follow
    # pulls the view: the caret lands third from the top, not first.
    CONTEXT_ROWS =          2
    ID_PREFIX    = "kodkod/code_editor/"
    FONT_MIN     = 8.0
    FONT_MAX     = 40.0
    # Lines longer than this skip the Ctrl-link identifier scan (see
    # the link block in #ui) — the col_x prefix measures would go
    # quadratic on minified files.
    LINK_SCAN_MAX_CHARS = 1_000

    def initialize(@buffer : EditorBuffer, @focus_id : String? = nil,
                   @keyboard : Bool = true,
                   @escape_clears_focus : Bool = true,
                   @tab : String = "    ", @rows : Int32 = 25,
                   @cursor_style : Symbol = :block,
                   @cursor_blinks : Bool = true,
                   @cursor_line : Bool = true,
                   @syntax_highlight : Bool = true,
                   @on_context_menu : (Egui::Ui ->)? = nil,
                   # Go-to-definition hooks (see the link block in #ui):
                   # `on_ctrl_click` receives the caret offset under a
                   # Ctrl+click; `link_lookup` says whether a word has
                   # indexed definitions (drives the Ctrl underlines).
                   @on_ctrl_click : (Int32 ->)? = nil,
                   @link_lookup : (String -> Bool)? = nil)
    end

    # Global (ui-scope-independent) widget id — see the file header.
    def self.widget_id(focus_id : String) : Egui::Id
      Egui::Id.from(ID_PREFIX + focus_id)
    end

    # The shared cell behind the Ctrl+Minus / Ctrl+Equal font zoom —
    # keyed by the ID_PREFIX base (no focus_id), so every editor tab
    # zooms together. 0.0 = no override (the theme's size).
    def self.font_cell : Egui::Id
      Egui::Id.from(ID_PREFIX).child(FONT_SALT)
    end

    # Zoom every editor's font by `delta` WHOLE points (base = the
    # theme size on the first press), clamped to FONT_MIN..FONT_MAX.
    def self.zoom(ctx : Egui::Context, delta : Int32) : Nil
      cur = ctx.memory.data.get_f64(font_cell, 0.0)
      base = cur > 0.0 ? cur : ctx.style.font_size
      size = (base + delta).round.clamp(FONT_MIN, FONT_MAX)
      ctx.memory.data.set_f64(font_cell, size)
      ctx.request_repaint
    end

    # --- public caret/selection API ---------------------------------
    # All methods that map offsets take the buffer: offsets are char
    # indexes into ITS rope, and only the rope can map line/col.

    def self.cursor_offset(ctx : Egui::Context, focus_id : String) : Int32
      id = widget_id(focus_id)
      ctx.memory.data.get_int(id, 0)
    end

    def self.cursor(ctx : Egui::Context, buffer : EditorBuffer,
                    focus_id : String) : {Int32, Int32}
      buffer.rope.line_col_of(cursor_offset(ctx, focus_id)
        .clamp(0, buffer.rope.size))
    end

    def self.set_cursor(ctx : Egui::Context, buffer : EditorBuffer,
                        focus_id : String, line : Int32, col : Int32,
                        extend_sel : Bool = false) : Nil
      set_cursor_offset(ctx, buffer, focus_id,
        buffer.rope.offset_at(line, col), extend_sel)
    end

    def self.set_cursor_offset(ctx : Egui::Context, buffer : EditorBuffer,
                               focus_id : String, offset : Int32,
                               extend_sel : Bool = false) : Nil
      id = widget_id(focus_id)
      cursor = ctx.memory.data.get_int(id, 0)
      ctx.memory.data.set_int(id, offset.clamp(0, buffer.rope.size))
      unless extend_sel
        ctx.memory.data.set_int(id.child(ANCHOR_SALT), offset.clamp(0, buffer.rope.size))
      end
      # A direct caret jump names the sticky column too (a click or a
      # :123 command means THIS column, not the previous one).
      ctx.memory.data.set_int(id.child(COL_SALT),
        buffer.rope.line_col_of(offset)[1])
      ctx.request_repaint
      cursor
    end

    # {min, max} char offsets of the selection, or nil when collapsed.
    def self.selection(ctx : Egui::Context, focus_id : String) : {Int32, Int32}?
      id = widget_id(focus_id)
      cursor = ctx.memory.data.get_int(id, 0)
      anchor = ctx.memory.data.get_int(id.child(ANCHOR_SALT), -1)
      return nil if anchor < 0 || anchor == cursor
      {Math.min(cursor, anchor), Math.max(cursor, anchor)}
    end

    def self.set_selection(ctx : Egui::Context, focus_id : String,
                           from : Int32, to : Int32) : Nil
      id = widget_id(focus_id)
      ctx.memory.data.set_int(id, from)
      ctx.memory.data.set_int(id.child(ANCHOR_SALT), to)
      ctx.request_repaint
    end

    def self.selection_text(ctx : Egui::Context, buffer : EditorBuffer,
                            focus_id : String) : String
      if (sel = selection(ctx, focus_id))
        buffer.rope.slice(sel[0], sel[1] - sel[0])
      else
        ""
      end
    end

    def self.replace_range(ctx : Egui::Context, buffer : EditorBuffer,
                           focus_id : String, from : Int32, count : Int32,
                           text : String) : Int32
      buffer.apply(from, text, count)
      set_cursor_offset(ctx, buffer, focus_id, from + text.size)
      scroll_to_line(ctx, focus_id, buffer.rope.line_of(from + text.size))
      from + text.size
    end

    # Replace the selection (or insert at the caret) and place the
    # caret after the inserted text — the VIM layer's p/o/i path.
    def self.insert_text(ctx : Egui::Context, buffer : EditorBuffer,
                         focus_id : String, text : String) : Int32
      at = cursor_offset(ctx, focus_id)
      count = 0
      if (sel = selection(ctx, focus_id))
        at = sel[0]
        count = sel[1] - sel[0]
      end
      replace_range(ctx, buffer, focus_id, at, count, text)
    end

    def self.delete_chars(ctx : Egui::Context, buffer : EditorBuffer,
                          focus_id : String, from : Int32,
                          count : Int32) : Nil
      replace_range(ctx, buffer, focus_id, from, count, "")
    end

    def self.undo(ctx : Egui::Context, buffer : EditorBuffer,
                  focus_id : String) : Bool
      if (r = buffer.undo)
        _edit, hint = r
        set_cursor_offset(ctx, buffer, focus_id, hint)
        ctx.request_repaint
        true
      else
        false
      end
    end

    def self.redo(ctx : Egui::Context, buffer : EditorBuffer,
                  focus_id : String) : Bool
      if (r = buffer.redo)
        _edit, hint = r
        set_cursor_offset(ctx, buffer, focus_id, hint)
        ctx.request_repaint
        true
      else
        false
      end
    end

    # Scroll so `line` is visible (centered when `center`); uses the
    # metrics the widget published to memory last frame.
    def self.scroll_to_line(ctx : Egui::Context, focus_id : String,
                            line : Int32, center : Bool = false) : Nil
      id = widget_id(focus_id)
      scroll_id = id.child(SCROLL_SALT)
      line_h = ctx.memory.data.get_f64(id.child(LINE_H_SALT), 20.0)
      view_h = ctx.memory.data.get_f64(id.child(VIEW_H_SALT), 400.0)
      y = line.to_f64 * line_h
      off = ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y
      off = center ? y - view_h / 2.0 : off
      if !center
        off = y if y < off
        off = y + line_h - view_h if y + line_h > off + view_h
      end
      max_off = {y + line_h * 2.0 - view_h, 0.0}.max # rough clamp
      # One-sided: never PULL the view up — an over-scrolled view (the
      # buffer shrank under it, see the v_off comment in #ui) may only
      # be reined in by real scrolling, not by a caret jump.
      off = off.clamp(0.0, {max_off, off}.max)
      ctx.memory.data.set_vec2(scroll_id,
        Egui::Vec2.new(ctx.memory.data.get_vec2(scroll_id, Egui::Vec2.zero).x,
          off))
      ctx.request_repaint
    end

    def self.request_focus(ctx : Egui::Context, focus_id : String) : Nil
      ctx.memory.focus.request(widget_id(focus_id))
    end

    # Land the caret at LINE (0-based), char column COL. Both clamp
    # into the buffer: a line past the end clamps to the last line, a
    # COL past the line's end TRIMS to the line end — each with a
    # one-line stderr warning (the caller asked for coordinates that
    # do not exist; silently eating them hides indexing bugs).
    #
    # The write also survives frames the editor does NOT render in
    # (a jump from the Indexing page): Memory prunes unused state
    # cells at end of frame, so the caret/scroll cells are marked
    # used here — without that the freshly written caret cell was
    # pruned the very frame of the jump and the cursor reset to 0.
    def self.goto_line(ctx : Egui::Context, buffer : EditorBuffer,
                       focus_id : String, line : Int32,
                       col : Int32 = 0) : Nil
      rope = buffer.rope
      li = line.clamp(0, {rope.line_count - 1, 0}.max)
      if li != line
        STDERR.puts "kodkod: goto_line line #{line} out of range " \
                    "(0..#{ {rope.line_count - 1, 0}.max }) — clamped to #{li}"
      end
      len = rope.line_length(li)
      ci = col.clamp(0, len)
      if ci != col
        STDERR.puts "kodkod: goto_line col #{col} past line end " \
                    "(#{len}) — trimmed to #{ci}"
      end
      id = widget_id(focus_id)
      ctx.memory.use_id(id)
      ctx.memory.use_id(id.child(ANCHOR_SALT))
      ctx.memory.use_id(id.child(COL_SALT))
      ctx.memory.use_id(id.child(SEEN_SALT))
      ctx.memory.use_id(id.child(SCROLL_SALT))
      set_cursor(ctx, buffer, focus_id, li, ci)
      scroll_to_line(ctx, focus_id, li, center: true)
    end

    # The identifier (word) around `offset`, as {start, end} char
    # offsets into the rope — the app's go-to-definition lookup scope.
    # nil when the offset sits on no identifier.
    def self.word_at(rope : Rope, offset : Int32) : {Int32, Int32}?
      offset = offset.clamp(0, rope.size)
      line, col = rope.line_col_of(offset)
      text = rope.line_text(line)
      return nil if text.empty?
      w0, w1 = CodeEditor.word_range(text, col.clamp(0, text.size - 1))
      return nil if w1 <= w0
      s = rope.line_start(line)
      {s + w0, s + w1}
    end

    # --- widget ------------------------------------------------------

    def ui(ui : Egui::Ui) : Egui::Response
      style = effective_style(ui)
      font_size = style.font_size
      fonts = ui.ctx.fonts_for("monospace")
      memory = ui.ctx.memory
      # The shared Ctrl +/- zoom override (0 = the theme's size).
      font_id = CodeEditor.font_cell
      memory.use_id(font_id)
      if (zoom = memory.data.get_f64(font_id, 0.0)) > 0.0
        font_size = zoom
      end
      input = ui.ctx.input
      visuals = style.visuals
      rope = @buffer.rope
      lines = rope.line_count
      id = @focus_id ? CodeEditor.widget_id(@focus_id.not_nil!) : ui.next_widget_id
      anchor_id = id.child(ANCHOR_SALT)
      col_id = id.child(COL_SALT)
      seen_id = id.child(SEEN_SALT)
      scroll_id = id.child(SCROLL_SALT)
      vel_id = scroll_id.child(3)
      # State cells with no #interact call of their own must be marked
      # used or end-frame pruning drops them: the sticky column, the
      # metrics the class API (scroll_to_line) reads, and the running
      # max line width would all reset every frame.
      memory.use_id(anchor_id)
      memory.use_id(col_id)
      memory.use_id(seen_id)
      memory.use_id(vel_id)
      memory.use_id(id.child(LINE_H_SALT))
      memory.use_id(id.child(VIEW_H_SALT))
      memory.use_id(id.child(WMAX_SALT))
      memory.use_id(id.child(WMAXV_SALT))

      line_h = font_size * Egui::Fonts::LINE_H_FACTOR
      char_w = fonts.measure("M", font_size).x

      width = ui.available_width
      # A viewport, not a page: never claim more height than the Ui
      # has room for. A taller rect would make the visible window
      # (and the scrollbar / caret-follow math behind it) believe
      # off-screen rows are on-screen — the editor would not scroll
      # until the content passed `rows` lines, far below the fold.
      height = {@rows * line_h, {ui.available_height, line_h}.max}.min
      rect = ui.allocate_at_least(Egui::Vec2.new(width, height))
      response = ui.interact(rect, id,
        Egui::Sense::Click | Egui::Sense::Drag | Egui::Sense::Focusable)
      ui.ctx.set_cursor_icon(Egui::CursorIcon::Text) if response.hovered?

      # Right-click menu, app-supplied (Cut/Copy/Paste/Select All via
      # the class API — works in EVERY VIM mode, where the widget
      # keyboard is off and Ctrl+C/Backspace never reach
      # handle_keyboard). A secondary press never registers as
      # pressed?/clicked? (primary-only), so the drag selection under
      # the pointer survives the menu opening.
      if (cm = @on_context_menu)
        response.context_menu { |menu| cm.call(menu) }
      end

      digits = {lines.to_s.size, 3}.max
      gutter_w = digits.to_f64 * char_w + GUTTER_PAD * 2.0
      inner = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + gutter_w + TEXT_PAD, rect.top),
        Egui::Vec2.new({rect.width - gutter_w - BAR_W - TEXT_PAD, char_w}.max,
          rect.height))
      view_h = inner.height
      view_w = inner.width
      memory.data.set_f64(id.child(LINE_H_SALT), line_h)
      memory.data.set_f64(id.child(VIEW_H_SALT), view_h)

      content_h = lines.to_f64 * line_h
      max_offset = {content_h - view_h, 0.0}.max

      # Running max line width (content width for the horizontal
      # scrollbar) — only laid-out lines contribute, so it grows as
      # the user scrolls long lines past. The previous frame's value
      # stays in force UNTIL this frame's rows are measured below:
      # zeroing it here on a version bump used to clamp h_off to 0
      # for a frame (the clamp below), snapping the view to column 0
      # on every edit of a long line. The shrink to freshly measured
      # widths happens at the row-build store below.
      wm_ver = id.child(WMAXV_SALT)
      wm_id = id.child(WMAX_SALT)
      wmax = memory.data.get_f64(wm_id, 0.0)

      # --- vertical kinetic scroll + horizontal wheel -----------------
      memory.register_scroll_area(scroll_id, rect, ui.layer)
      kin = Egui::KineticScroller.new(
        memory.data.get_vec2(scroll_id, Egui::Vec2.zero).y,
        memory.data.get_f64(vel_id, 0.0),
        memory.scroll_history(scroll_id))
      h_off = memory.data.get_vec2(scroll_id, Egui::Vec2.zero).x
      if memory.active_scroll_area? == scroll_id && !input.scroll.y.zero?
        if input.modifiers.shift
          # scroll.y < 0 is wheel-up; +scroll.y → view-right, so
          # wheel-up must DECREASE h_off (browser/GTK/ScrollArea
          # convention: shift+wheel-up scrolls toward column 0).
          h_off += input.scroll.y * char_w * 3.0
          kin.takeover
        else
          kin.input(input.scroll.y * style.scroll_speed, input.time,
            max_offset)
        end
      else
        kin.glide(input.dt, max_offset, ui.ctx)
      end
      # Touchpad horizontal / tilt wheel (scroll.x — X11 buttons 6/7,
      # Wayland axis): a positive notch means view-LEFT (sokol
      # convention, same direction family as shift+wheel-up). Runs
      # alongside the vertical branch — a diagonal swipe drives both
      # axes, and a horizontal-only swipe leaves any vertical glide
      # running untouched.
      if memory.active_scroll_area? == scroll_id && !input.scroll.x.zero?
        h_off -= input.scroll.x * char_w * 3.0
      end
      # VIM-like topline: an over-scroll past max_offset (content just
      # shrank — dd at the file end) is allowed to STAY — clamping here
      # would yank every visible row down a line the moment a deletion
      # shortens the buffer. All input paths (wheel, glide, scrollbar,
      # scroll_to_line) clamp into range themselves, so the overshoot
      # only ever shows as blank rows under the last line, like vim.
      v_off = {kin.offset, 0.0}.max
      h_off = h_off.clamp(0.0, {wmax + char_w * 4.0 - view_w, 0.0}.max)

      # --- visible window of lines ------------------------------------
      lv0 = (v_off / line_h).floor.to_i.clamp(0, {lines - 1, 0}.max)
      lv1 = ((v_off + view_h) / line_h).ceil.to_i.clamp(0, lines)
      k1 = {lv1, lines}.min
      k1 = {k1, {lv0 + 1, lines}.min}.max # degenerate zero-height view

      cursor = memory.data.get_int(id, 0).clamp(0, rope.size)
      cursor_prev = cursor
      # The caret as last RENDERED. Class-API caret jumps (VIM's
      # w/$/f, :123, quick-open) write the cursor cell BETWEEN frames,
      # so `cursor != cursor_prev` cannot see them — both sides read
      # the same already-updated cell this frame. Comparing against
      # the seen cell can, arming the caret-follow below: a caret that
      # jumped off-screen from OUTSIDE the frame must still scroll the
      # view to itself.
      cursor_seen = memory.data.get_int(seen_id, cursor)
      anchor = memory.data.get_int(anchor_id, -1)
      edited = false

      # --- mouse: click places the caret, drag selects ----------------
      # A Ctrl+click with go-to-definition armed is a LINK click: the
      # app resolves the word under the pointer (jump or candidates)
      # and the caret/selection stay where they were — like every
      # browser/IDE link. Words in PROSE tokens (comments, strings)
      # are not links — the same gate the underline layer uses — so a
      # Ctrl+click there degrades to a normal caret placement.
      link_spans = @syntax_highlight ? @buffer.token_spans : nil
      if (ctrl_cb = @on_ctrl_click) && input.modifiers.ctrl &&
         (response.pressed? || response.clicked?) && (pos = input.pointer_pos)
        at = caret_at(inner, pos, v_off, h_off, fonts, font_size,
          line_h, rope)
        response.request_focus
        if linkable_at?(link_spans, at)
          ctrl_cb.call(at)
          cursor = at # a link click parks the caret on the word
          anchor = at
        elsif response.double_clicked?
          line, _col = rope.line_col_of(at)
          w0, w1 = CodeEditor.word_range(rope.line_text(line),
            at - rope.line_start(line))
          cursor = rope.line_start(line) + w0
          anchor = rope.line_start(line) + w1
        else
          cursor = at
          anchor = at
        end
      elsif response.pressed? || response.clicked?
        response.request_focus
        if (pos = input.pointer_pos)
          at = caret_at(inner, pos, v_off, h_off, fonts, font_size, line_h, rope)
          if response.double_clicked?
            line, _col = rope.line_col_of(at)
            w0, w1 = CodeEditor.word_range(rope.line_text(line), at - rope.line_start(line))
            cursor = rope.line_start(line) + w0
            anchor = rope.line_start(line) + w1
          else
            cursor = at
            anchor = at
          end
        end
      end
      if response.drag_started? && (pos = input.pointer_pos) && anchor == -1
        anchor = caret_at(inner, pos, v_off, h_off, fonts, font_size, line_h, rope)
      end
      if response.dragged? && (pos = input.pointer_pos)
        cursor = caret_at(inner, pos, v_off, h_off, fonts, font_size, line_h, rope)
      end

      # --- keyboard (insert mode / standard input) --------------------
      # The Ctrl +/- font zoom runs in EVERY mode — VIM normal mode
      # turns the widget keyboard off (@keyboard false), but the editor
      # still holds focus, so the zoom lives here, not handle_keyboard.
      if response.has_focus? && input.modifiers.ctrl
        CodeEditor.zoom(ui.ctx, -1) if input.consume_key(Egui::KeyCode::Minus)
        CodeEditor.zoom(ui.ctx, 1) if input.consume_key(Egui::KeyCode::Equal)
      end
      if @keyboard && response.has_focus?
        ui.ctx.memory.focus.lock_arrows(horizontal: true, vertical: true)
        # A textarea owns its Tab: focus navigation (Memory#navigate_focus)
        # runs BEFORE any widget renders and consumes the Tab keypress
        # unless the focused widget claims the whole keyboard — the Tab
        # branch in handle_keyboard would never fire without this lock.
        ui.ctx.memory.focus.lock_keyboard
        cursor, anchor, edited = handle_keyboard(ui.ctx, cursor, anchor,
          view_h, line_h, col_id)
        ui.ctx.request_repaint if @cursor_blinks # caret blink
      end
      cursor = cursor.clamp(0, rope.size)
      anchor = -1 if anchor > rope.size

      # --- follow the caret -------------------------------------------
      # `cursor != cursor_seen` covers between-frame jumps (see the
      # seen-cell comment above); the other two cover in-frame moves
      # (keyboard/mouse) and edits.
      if edited || cursor != cursor_prev || cursor != cursor_seen
        kin.takeover
        line = rope.line_of(cursor)
        y = line.to_f64 * line_h
        # Two-sided, like scroll_to_line: push down when the caret is
        # below the view, pull up when it is above. The pull-up is what
        # keeps Backspace (eating newlines makes the caret climb fast
        # while the buffer shrinks) from outrunning the top of the
        # view — without it the content ends up entirely above the
        # viewport and the screen goes blank. Both edges keep
        # CONTEXT_ROWS rows of text past the caret (three rows stay
        # readable around it, never just the caret row), and the
        # trigger fires as soon as the caret ENTERS the margin — the
        # view then steps one line per move, not one big corrective
        # jump once the edge is finally hit. The context margin is
        # capped by the end of the buffer (rope.line_count is fresh —
        # an edit inside this frame already shrank it): at EOF the
        # caret rides down to the very bottom of the view instead of
        # idling two phantom rows above it.
        if y + line_h > v_off + view_h - CONTEXT_ROWS * line_h
          v_off = { {y + CONTEXT_ROWS * line_h + line_h - view_h,
                     rope.line_count.to_f64 * line_h - view_h}.min, 0.0 }.max
        elsif y < v_off + CONTEXT_ROWS * line_h
          v_off = {y - CONTEXT_ROWS * line_h, 0.0}.max
        end
        col = rope.line_col_of(cursor)[1]
        cx = col_x(rope.line_text(line), col, fonts, font_size)
        if cx + char_w > h_off + view_w
          h_off = cx + char_w - view_w
        elsif cx < h_off
          h_off = cx
        end
        # The clamp's extent rides the possibly-stale wmax; the
        # caret's own column is always a valid lower bound for the
        # content width (this edit may have just WIDENED the line
        # past the stored maximum — clamping against the stale value
        # would park the caret past the right edge).
        extent = {wmax, cx + char_w * 4.0}.max + char_w * 4.0 - view_w
        h_off = h_off.clamp(0.0, {extent, 0.0}.max)
      end

      memory.data.set_int(id, cursor)
      memory.data.set_int(seen_id, cursor)
      memory.data.set_int(anchor_id, anchor)
      memory.data.set_int(col_id, rope.line_col_of(cursor)[1]) unless
        @keyboard && response.has_focus? && vertical_key?(input)

      # An edit made INSIDE this frame (Backspace/Delete/typing via
      # handle_keyboard) may have shrunk the rope after the visible
      # window was sized. Refresh it: the stale window would ask for a
      # row past the end, and line_text CLAMPS — the deleted last line's
      # row would repaint the new last line's text on it for a frame.
      lines = rope.line_count
      content_h = lines.to_f64 * line_h
      max_offset = {content_h - view_h, 0.0}.max
      lv0 = (v_off / line_h).floor.to_i.clamp(0, {lines - 1, 0}.max)
      lv1 = ((v_off + view_h) / line_h).ceil.to_i.clamp(0, lines)
      k1 = {lv1, lines}.min
      k1 = {k1, {lv0 + 1, lines}.min}.max # degenerate zero-height view

      # --- build the visible rows (measured runs, no layout pass) ------
      # Row geometry without a Fonts#layout pass: the ascent (baseline
      # offset from the row top) mirrors the shard's legacy default —
      # em box centered on the row center, (height + em) / 2 — so
      # paint_galley places the glyphs exactly on the row centers.
      asc, desc = fonts.metrics_at(font_size)
      row_ascent = (line_h + asc - desc) / 2.0
      spans = @syntax_highlight ? @buffer.token_spans : nil
      rows = [] of Egui::Galley::Row
      # Horizontal window of the viewport (columns outside it are
      # clipped anyway). Runs fully outside it are NOT emitted: a
      # minified one-line file must not measure and tessellate its
      # whole 27k-char line every frame — only the viewport-wide
      # slice, the way professional editors clip long lines to the
      # horizontal scroll window (VSCode/Sublime render just the
      # visible columns). Row WIDTH stays the full line's — it feeds
      # wmax and thus the hscroll extent.
      vis_l = h_off - char_w * 2.0
      vis_r = h_off + view_w + char_w * 2.0
      fresh = 0.0 # this frame's max over measured (visible) rows
      (lv0...k1).each do |li|
        s = rope.line_start(li)
        text = rope.line_text(li)
        runs = [] of Egui::Galley::RowRun
        # Widths are ACCUMULATED run by run (each fragment measured
        # once); the old per-run col_x re-measured the whole prefix,
        # making a long line quadratic — one 27k-char line spent
        # seconds per frame in col_x.
        if (sp = spans)
          starts, toks = sp
          # First token whose END is past the line start (binary
          # search; token i spans [starts[i], starts[i+1])).
          lo = 0
          hi = toks.size
          while lo < hi
            mid = (lo + hi) // 2
            if starts[mid + 1] > s
              hi = mid
            else
              lo = mid + 1
            end
          end
          i = lo
          line_end = s + text.size
          acc = 0.0
          while i < toks.size && starts[i] < line_end
            tok_s = {starts[i], s}.max
            tok_e = {starts[i + 1], line_end}.min
            if tok_e > tok_s
              frag = text[tok_s - s...tok_e - s]
              fw = fonts.measure(frag, font_size).x
              if acc < vis_r && acc + fw >= vis_l
                color = Syntax::Palette.color(toks[i].scope, visuals.dark)
                runs << Egui::Galley::RowRun.new(frag,
                  acc, font_size, color, false)
              end
              acc += fw
            end
            i += 1
          end
          runs << Egui::Galley::RowRun.new("", 0.0, font_size, nil, false) if runs.empty?
          w = acc
        else
          runs, w = plain_line_runs(text, fonts, font_size, vis_l, vis_r)
        end
        rows << Egui::Galley::Row.new(runs, w, line_h, li.to_f64 * line_h,
          row_ascent, li > 0)
        wmax = {wmax, w}.max
        fresh = {fresh, w}.max
      end
      # Version bumped since the stored max (an edit): the stored
      # value may outlive lines that shrank or vanished — reseed it
      # from the widths just measured. The stale maximum still serves
      # this frame's scrollbar/clamps (wmax above), so the extent
      # never dips to 0 mid-edit.
      if memory.data.get_int(wm_ver, -1) != rope.version
        memory.data.set_int(wm_ver, rope.version)
        memory.data.set_f64(wm_id, fresh)
      else
        memory.data.set_f64(wm_id, wmax)
      end
      galley = Egui::Galley.new(rows)

      # --- painting ----------------------------------------------------
      painter = ui.painter
      painter.rect(rect, 0.0, visuals.window_fill)
      gutter_rect = Egui::Rect.from_min_size(rect.min,
        Egui::Vec2.new(gutter_w, rect.height))
      painter.rect(gutter_rect, 0.0,
        visuals.fade_color(visuals.window_fill, visuals.dark ? 0.6 : 0.97))
      painter.line(Egui::Pos2.new(gutter_rect.right, rect.top),
        Egui::Pos2.new(gutter_rect.right, rect.bottom), 1.0,
        visuals.separator_color)

      outer_clip = painter.clip
      painter.clip = Egui::Rect.new(
        Egui::Pos2.new({outer_clip.min.x, inner.min.x}.max,
          {outer_clip.min.y, inner.min.y}.max),
        Egui::Pos2.new({outer_clip.max.x, inner.max.x}.min,
          {outer_clip.max.y, inner.max.y}.min))

      cursor_line = rope.line_of(cursor)

      # Current-line highlight (subtle full-width band, VSCode-style):
      # a neutral band — window_fill nudged towards the text color
      # (lighter on dark themes, darker on light ones), never the
      # saturated selection blue. Runs from the gutter separator to the
      # inner right edge — starting it at inner.min.x (which carries
      # TEXT_PAD) left a background slit between the line and the band.
      # Suppressed in VIM mode (cursor_line: false) — vim highlights
      # the caret cell, not the whole line.
      if @cursor_line
        cl_y = inner.min.y + cursor_line.to_f64 * line_h - v_off
        if cl_y >= inner.min.y - line_h && cl_y < inner.max.y
          painter.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(gutter_rect.right, cl_y),
            Egui::Vec2.new(inner.max.x - gutter_rect.right, line_h)), 0.0,
            visuals.window_fill.lerp(visuals.text_color, 0.06))
        end
      end

      # Selection, per visible line, painted UNDER the text.
      if anchor >= 0 && anchor != cursor
        sel_min = {cursor, anchor}.min
        sel_max = {cursor, anchor}.max
        (lv0...k1).each do |li|
          s = rope.line_start(li)
          len = rope.line_length(li)
          a = {sel_min, s}.max
          b = {sel_max, s + len}.min
          next if b < a
          text = rope.line_text(li)
          x0 = inner.min.x + col_x(text, a - s, fonts, font_size) - h_off
          x1 = inner.min.x + col_x(text, b - s, fonts, font_size) - h_off
          x1 += char_w * 0.5 if sel_max > s + len # continues past \n
          y = inner.min.y + li.to_f64 * line_h - v_off
          painter.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(x0, y), Egui::Vec2.new({x1 - x0, 2.0}.max, line_h)),
            0.0, visuals.fade_color(visuals.selection_fill, 0.45))
        end
      end

      painter.paint_galley(inner.min - Egui::Vec2.new(h_off, v_off),
        galley, fonts, visuals.text_color, "monospace")

      # --- Ctrl link highlighting (go-to-definition) -------------------
      # While Ctrl is held, every identifier in view with indexed
      # definitions gets a hyperlink underline, and the pointer over
      # one of them turns into the pointing hand. Token-AWARE: the
      # scan walks the highlight.cr spans (binary search per visible
      # line, same as the row builder) and skips PROSE tokens —
      # comments, strings, regexps — where an indexed word is just a
      # word, not a reference (the old raw-text scan underlined them
      # everywhere: mass false positives in comments). Without spans
      # (unknown language, huge file, highlighting off) it degrades to
      # the raw per-line scan — name-based nav still beats nothing.
      # One hash probe per identifier run per frame; monster lines
      # skip the scan (a minified 27k-char line must not pay quadratic
      # col_x measures for underline x-positions).
      if (ll = @link_lookup) && input.modifiers.ctrl
        if response.hovered? && (pos = input.pointer_pos)
          at = caret_at(inner, pos, v_off, h_off, fonts, font_size,
            line_h, rope)
          line, col = rope.line_col_of(at)
          text = rope.line_text(line)
          w0, w1 = CodeEditor.word_range(text, col.clamp(0, text.size - 1))
          if w1 > w0 && ll.call(text[w0...w1]) &&
             linkable_at?(link_spans, at)
            ui.ctx.set_cursor_icon(Egui::CursorIcon::Pointer)
          end
        end
        (lv0...k1).each do |li|
          text = rope.line_text(li)
          next if text.size > LINK_SCAN_MAX_CHARS
          s = rope.line_start(li)
          line_end = s + text.size
          if (sp = link_spans)
            starts, toks = sp
            lo = 0
            hi = toks.size
            while lo < hi # first token whose END is past the line start
              mid = (lo + hi) // 2
              if starts[mid + 1] > s
                hi = mid
              else
                lo = mid + 1
              end
            end
            i = lo
            while i < toks.size && starts[i] < line_end
              frag_s = {starts[i], s}.max
              frag_e = {starts[i + 1], line_end}.min
              if Syntax.linkable_scope?(toks[i].scope) && frag_e > frag_s
                underline_runs(text, frag_s - s, frag_e - s, ll, li,
                  inner, h_off, v_off, line_h, row_ascent, fonts,
                  font_size, painter, visuals.hyperlink_color)
              end
              i += 1
            end
          else
            underline_runs(text, 0, text.size, ll, li, inner, h_off,
              v_off, line_h, row_ascent, fonts, font_size, painter,
              visuals.hyperlink_color)
          end
        end
      end

      # Caret while focused; it BLINKS unless `cursor_blinks: false`
      # holds it steady (VIM's cursor never blinks).
      # :block (VIM normal/visual) fills
      # the character's MEASURED cell (the font's real advance — a
      # col*char_w grid drifts as fallback glyphs advance differently)
      # and re-draws the character under it in the editor background
      # (inverse video); :bar (VIM insert) is a thin bar at the cell's
      # left edge. Both track the row's TEXT geometry, not the row
      # center: the galley baseline (row_ascent) seats the em box |desc|
      # BELOW the row center (desc < 0), so a row-centered caret and
      # inverse char read a couple pixels higher than the glyphs.
      if response.has_focus? &&
         (@cursor_blinks ? (input.time % 1.0) < 0.6 : true)
        line, col = rope.line_col_of(cursor)
        text = rope.line_text(line)
        x = inner.min.x + col_x(text, col, fonts, font_size) - h_off
        baseline = inner.min.y + line.to_f64 * line_h - v_off + row_ascent
        box_top = baseline - asc + 1.0 # em box, inset 1px like a row band
        box_h = {asc - desc - 2.0, 2.0}.max
        if @cursor_style == :bar
          painter.rect(Egui::Rect.from_min_size(Egui::Pos2.new(x, box_top),
            Egui::Vec2.new(2.0, box_h)), 0.0, visuals.text_color)
        else
          w = col_x(text, col + 1, fonts, font_size) -
              col_x(text, col, fonts, font_size)
          w = fonts.measure(" ", font_size).x if w <= 0.0 # EOL cell
          painter.rect(Egui::Rect.from_min_size(Egui::Pos2.new(x, box_top),
            Egui::Vec2.new(w, box_h)), 0.0, visuals.text_color)
          if (ch = text[col]?)
            # The run's own anchor (paint_galley): baseline minus half
            # the em box — lands the inverse glyph exactly on its ink.
            painter.text(Egui::Pos2.new(x, baseline - (asc + desc) / 2.0),
              ch.to_s, font_size, visuals.window_fill, family: "monospace")
          end
        end
      end

      painter.clip = outer_clip

      # Gutter numbers. Anchored on the row's TEXT geometry like the
      # caret above: the galley baseline seats the em box |desc| below
      # the row center, so a plain row-center y reads a couple pixels
      # higher than the line's glyphs.
      num_color = visuals.fade_color(visuals.text_color, 0.5)
      (lv0...k1).each do |li|
        y = rect.top + li.to_f64 * line_h - v_off +
            row_ascent - (asc + desc) / 2.0
        next if y < rect.top - line_h || y > rect.bottom + line_h
        label = (li + 1).to_s
        x = gutter_rect.right - GUTTER_PAD - fonts.measure(label, font_size).x
        painter.text(Egui::Pos2.new(x, y), label, font_size,
          li == cursor_line ? visuals.text_color : num_color,
          family: "monospace")
      end

      # --- scrollbars --------------------------------------------------
      kin_velocity = kin.velocity
      if content_h > view_h && view_h > 0.0
        track = Egui::Rect.from_min_size(
          Egui::Pos2.new(rect.right - BAR_W, rect.top),
          Egui::Vec2.new(BAR_W, rect.height))
        bar_id = id.child(BAR_SALT)
        bar_resp = ui.interact(track, bar_id, Egui::Sense.click_and_drag)

        thumb_h = (view_h * view_h / content_h).clamp(12.0, view_h)
        scrollable = view_h - thumb_h
        # The thumb sits at the clamped offset — an over-scrolled view
        # (see v_off above) parks the thumb at the track's end.
        v_thumb = v_off.clamp(0.0, max_offset)
        thumb_y = ->(off : Float64) : Float64 do
          max_offset > 0.0 ? track.top + scrollable * off / max_offset : track.top
        end

        if (bar_resp.pressed? || bar_resp.dragged?) && (pointer = input.pointer_pos)
          kin.takeover
          kin_velocity = 0.0
          grab = memory.data.get_f64(bar_id, Float64::NAN)
          if grab.nan?
            thumb_now = Egui::Rect.from_min_size(
              Egui::Pos2.new(track.left, thumb_y.call(v_thumb)),
              Egui::Vec2.new(BAR_W, thumb_h))
            grab = thumb_now.contains?(pointer) ? pointer.y - thumb_now.top : thumb_h / 2.0
            memory.data.set_f64(bar_id, grab)
          end
          if scrollable > 0.0
            v_off = ((pointer.y - grab - track.top) * max_offset / scrollable)
              .clamp(0.0, max_offset)
          end
        else
          memory.data.set_f64(bar_id, Float64::NAN)
        end

        painter.rect(track, 4.0, visuals.fade_color(visuals.window_fill, 0.9))
        thumb = Egui::Rect.from_min_size(
          Egui::Pos2.new(track.left + 1.0, thumb_y.call(v_thumb) + 1.0),
          Egui::Vec2.new(BAR_W - 2.0, {thumb_h - 2.0, 4.0}.max))
        thumb_color = visuals.button_hovered if bar_resp.hovered?
        thumb_color = visuals.button_active if bar_resp.pressed? || bar_resp.dragged?
        thumb_color ||= visuals.button_weak
        painter.rect(thumb, 3.0, thumb_color, visuals.button_stroke, 1.0)
      end

      content_w = wmax + char_w * 4.0
      if content_w > view_w && view_w > 0.0
        track = Egui::Rect.from_min_size(
          Egui::Pos2.new(inner.left, rect.bottom - HBAR_H),
          Egui::Vec2.new(view_w, HBAR_H))
        hbar_id = id.child(HBAR_SALT)
        h_resp = ui.interact(track, hbar_id, Egui::Sense.click_and_drag)
        h_max = content_w - view_w
        thumb_w = (view_w * view_w / content_w).clamp(20.0, view_w)
        scrollable = view_w - thumb_w
        thumb_x = ->(off : Float64) : Float64 do
          h_max > 0.0 ? track.left + scrollable * off / h_max : track.left
        end
        if (h_resp.pressed? || h_resp.dragged?) && (pointer = input.pointer_pos)
          grab = memory.data.get_f64(hbar_id, Float64::NAN)
          if grab.nan?
            thumb_now = Egui::Rect.from_min_size(
              Egui::Pos2.new(thumb_x.call(h_off), track.top),
              Egui::Vec2.new(thumb_w, HBAR_H))
            grab = thumb_now.contains?(pointer) ? pointer.x - thumb_now.left : thumb_w / 2.0
            memory.data.set_f64(hbar_id, grab)
          end
          if scrollable > 0.0
            h_off = ((pointer.x - grab - track.left) * h_max / scrollable)
              .clamp(0.0, h_max)
          end
        else
          memory.data.set_f64(hbar_id, Float64::NAN)
        end
        painter.rect(Egui::Rect.from_min_size(
          Egui::Pos2.new(thumb_x.call(h_off), track.top + 1.0),
          Egui::Vec2.new({thumb_w - 2.0, 4.0}.max, HBAR_H - 2.0)), 3.0,
          visuals.button_weak, visuals.button_stroke, 1.0)
      end

      memory.data.set_vec2(scroll_id, Egui::Vec2.new(h_off, v_off))
      memory.data.set_f64(vel_id, kin_velocity)

      response.mark_changed if edited
      response
    end

    # --- keyboard ------------------------------------------------------

    # Returns {cursor, anchor, edited}.
    private def handle_keyboard(ctx : Egui::Context, cursor : Int32,
                                anchor : Int32, view_h : Float64,
                                line_h : Float64, col_id : Egui::Id)
      input = ctx.input
      rope = @buffer.rope
      memory = ctx.memory
      new_cursor = cursor
      new_anchor = anchor
      edited = false
      size = rope.size
      has_sel = new_anchor >= 0 && new_anchor != new_cursor
      sel_min = has_sel ? {new_cursor, new_anchor}.min : 0
      sel_max = has_sel ? {new_cursor, new_anchor}.max : 0

      if @escape_clears_focus && input.consume_key(Egui::KeyCode::Escape)
        ctx.memory.focus.clear
        return {new_cursor, new_anchor, edited}
      end

      if input.modifiers.ctrl
        if input.consume_key(Egui::KeyCode::A)
          new_anchor = 0
          new_cursor = size
        elsif input.consume_key(Egui::KeyCode::C)
          if has_sel
            Egui::SystemPorts::Clipboard.text = rope.slice(sel_min, sel_max - sel_min)
          end
        elsif input.consume_key(Egui::KeyCode::X)
          if has_sel
            Egui::SystemPorts::Clipboard.text = rope.slice(sel_min, sel_max - sel_min)
            @buffer.apply(sel_min, "", sel_max - sel_min)
            new_cursor = new_anchor = sel_min
            edited = true
          end
        elsif input.consume_key(Egui::KeyCode::V)
          if (paste = Egui::SystemPorts::Clipboard.text)
            paste = paste.gsub(/\r\n|\r/, "\n")
            at = has_sel ? sel_min : new_cursor
            @buffer.apply(at, paste, has_sel ? sel_max - sel_min : 0)
            new_cursor = new_anchor = at + paste.size
            edited = true
          end
        elsif input.consume_key(Egui::KeyCode::Z)
          if (r = input.modifiers.shift ? @buffer.redo : @buffer.undo)
            _e, hint = r
            new_cursor = new_anchor = hint.clamp(0, rope.size)
            edited = true
          end
        elsif input.consume_key(Egui::KeyCode::Y)
          if (r = @buffer.redo)
            _e, hint = r
            new_cursor = new_anchor = hint.clamp(0, rope.size)
            edited = true
          end
        elsif input.consume_key(Egui::KeyCode::Home)
          new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
          new_cursor = 0
          new_anchor = new_cursor unless input.modifiers.shift
        elsif input.consume_key(Egui::KeyCode::End)
          new_anchor = new_cursor if new_anchor == -1 && input.modifiers.shift
          new_cursor = size
          new_anchor = new_cursor unless input.modifiers.shift
        end
        return {new_cursor, new_anchor, edited}
      end

      # Edits (selection-aware; offsets are char indexes, so a ±1 step
      # is one UTF-8 character — no byte walking needed).
      if input.consume_key(Egui::KeyCode::Backspace)
        if has_sel
          @buffer.apply(sel_min, "", sel_max - sel_min)
          new_cursor = new_anchor = sel_min
          edited = true
        elsif new_cursor > 0
          @buffer.apply(new_cursor - 1, "", 1)
          new_cursor = new_anchor = new_cursor - 1
          edited = true
        end
      elsif input.consume_key(Egui::KeyCode::Delete)
        if has_sel
          @buffer.apply(sel_min, "", sel_max - sel_min)
          new_cursor = new_anchor = sel_min
          edited = true
        elsif new_cursor < size
          @buffer.apply(new_cursor, "", 1)
          new_anchor = new_cursor
          edited = true
        end
      elsif input.consume_key(Egui::KeyCode::Enter)
        at = has_sel ? sel_min : new_cursor
        line = rope.line_of(at)
        indent = rope.line_text(line)[/\A[ \t]*/] || ""
        @buffer.apply(at, "\n" + indent, has_sel ? sel_max - sel_min : 0)
        new_cursor = new_anchor = at + 1 + indent.size
        edited = true
      elsif input.consume_key(Egui::KeyCode::Tab)
        at = has_sel ? sel_min : new_cursor
        @buffer.apply(at, @tab, has_sel ? sel_max - sel_min : 0)
        new_cursor = new_anchor = at + @tab.size
        edited = true
      elsif !input.text.empty? && !input.shortcut_modifiers_down?
        insert = input.text.gsub(/\r\n|\r/, "\n")
        at = has_sel ? sel_min : new_cursor
        @buffer.apply(at, insert, has_sel ? sel_max - sel_min : 0)
        new_cursor = new_anchor = at + insert.size
        edited = true
      end

      # Movement (after edits, so the caret lands in the new text).
      clamp = ->(b : Int32) { b.clamp(0, rope.size) }
      if input.consume_key(Egui::KeyCode::Left)
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = if !input.modifiers.shift && has_sel
          {new_cursor, new_anchor}.min
        else
          clamp.call(new_cursor - 1)
        end
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::Right)
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = if !input.modifiers.shift && has_sel
          {new_cursor, new_anchor}.max
        else
          clamp.call(new_cursor + 1)
        end
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::Up)
        line = rope.line_of(new_cursor)
        des = memory.data.get_int(col_id, rope.line_col_of(new_cursor)[1])
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = line_col_offset(rope, line - 1, des)
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::Down)
        line = rope.line_of(new_cursor)
        des = memory.data.get_int(col_id, rope.line_col_of(new_cursor)[1])
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = line_col_offset(rope, line + 1, des)
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::PageUp)
        line = rope.line_of(new_cursor)
        des = memory.data.get_int(col_id, rope.line_col_of(new_cursor)[1])
        page = {(view_h / line_h - 1.0).floor.to_i, 1}.max
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = line_col_offset(rope, line - page, des)
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::PageDown)
        line = rope.line_of(new_cursor)
        des = memory.data.get_int(col_id, rope.line_col_of(new_cursor)[1])
        page = {(view_h / line_h - 1.0).floor.to_i, 1}.max
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = line_col_offset(rope, line + page, des)
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::Home)
        line = rope.line_of(new_cursor)
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = rope.offset_at(line, 0)
        new_anchor = new_cursor unless input.modifiers.shift
      elsif input.consume_key(Egui::KeyCode::End)
        line = rope.line_of(new_cursor)
        new_anchor = new_cursor if input.modifiers.shift && new_anchor == -1
        new_cursor = rope.offset_at(line, rope.line_length(line))
        new_anchor = new_cursor unless input.modifiers.shift
      end

      {new_cursor, new_anchor, edited}
    end

    # Clamp a (line, col) pair into the rope and map it to an offset —
    # vertical movement's landing pad (the col sticks past short lines,
    # clamping only for the offset, never for the remembered column).
    private def line_col_offset(rope : Rope, line : Int32, col : Int32) : Int32
      l = line.clamp(0, rope.line_count - 1)
      rope.offset_at(l, col.clamp(0, rope.line_length(l)))
    end

    # A key whose handling must NOT overwrite the sticky desired column.
    private def vertical_key?(input : Egui::InputState) : Bool
      input.keys_pressed.any? do |k|
        Egui::KeyCode::Up == k || Egui::KeyCode::Down == k ||
          Egui::KeyCode::PageUp == k || Egui::KeyCode::PageDown == k
      end
    end

    # Measured x boundary before char `col` of a line text — the
    # font's REAL advances (what the rasterizer draws), never a
    # col*char_w grid: fallback faces advance differently and the
    # misalignment would accumulate with line length.
    private def col_x(text : String, col : Int32, fonts : Egui::Fonts,
                      font_size : Float64) : Float64
      fonts.measure(text[0, {col, text.size}.min], font_size).x
    end

    # Visible runs of an untokenized (plain) line, cut to the
    # horizontal window [vis_l, vis_r]. One measuring pass in CHUNKS —
    # each chunk measured once, widths accumulated — so a huge
    # untokenized file (over HIGHLIGHT_MAX_CHARS) stays O(line) per
    # frame with only the viewport slice emitted; chunk boundaries are
    # measured cumulative widths, so a run's x offset is exact (a
    # chunk may stick past a window edge — the painter clips it).
    # Chunk edges step to UTF-8 boundaries: a byte mid-character would
    # measure garbage. Returns {runs, full line width}.
    private def plain_line_runs(text : String, fonts : Egui::Fonts,
                                font_size : Float64, vis_l : Float64,
                                vis_r : Float64) : {Array(Egui::Galley::RowRun), Float64}
      runs = [] of Egui::Galley::RowRun
      acc = 0.0
      c = 0
      n = text.bytesize
      while c < n
        e = {c + 64, n}.min
        # Snap forward to the next char boundary (continuation bytes
        # are 10xxxxxx). e == n is always a boundary.
        while e < n && (text.byte_at(e) & 0xC0) == 0x80
          e += 1
        end
        frag = text.byte_slice(c, e - c)
        fw = fonts.measure(frag, font_size).x
        runs << Egui::Galley::RowRun.new(frag, acc, font_size, nil, false) if
          acc < vis_r && acc + fw >= vis_l
        acc += fw
        c = e
      end
      runs << Egui::Galley::RowRun.new("", 0.0, font_size, nil, false) if runs.empty?
      {runs, acc}
    end

    # Underline the identifier runs of text[from, to) whose words the
    # link lookup resolves — the Ctrl-link layer's paint pass (see
    # #ui). Runs are char columns on the line; positions come from the
    # MEASURED prefix widths (col_x) and are clipped to the viewport.
    private def underline_runs(text : String, from : Int32, to : Int32,
                               ll : String -> Bool, li : Int32,
                               inner : Egui::Rect, h_off : Float64,
                               v_off : Float64, line_h : Float64,
                               row_ascent : Float64,
                               fonts : Egui::Fonts, font_size : Float64,
                               painter : Egui::Painter,
                               link_color : Egui::Color32) : Nil
      col = from
      while col < to
        if CodeEditor.word_char?(text[col])
          s = col
          while col < to && CodeEditor.word_char?(text[col])
            col += 1
          end
          word = text[s...col]
          next unless ll.call(word)
          x0 = inner.min.x + col_x(text, s, fonts, font_size) - h_off
          x1 = x0 + fonts.measure(word, font_size).x
          next if x1 < inner.min.x || x0 > inner.max.x
          baseline = inner.min.y + li.to_f64 * line_h - v_off +
                     row_ascent
          painter.line(Egui::Pos2.new(x0, baseline + 2.0),
            Egui::Pos2.new(x1, baseline + 2.0), 1.0, link_color)
        else
          col += 1
        end
      end
    end

    # Whether `offset` sits in a token a Ctrl-link may act on (prose
    # tokens — comments, strings — say no; no spans → allow, the
    # raw-text fallback matches the underline layer).
    private def linkable_at?(spans : {Array(Int32), Array(Syntax::Token)}?,
                             offset : Int32) : Bool
      return true unless (sp = spans)
      starts, toks = sp
      lo = 0
      hi = toks.size # last token with starts[i] <= offset
      while lo < hi
        mid = (lo + hi) // 2
        if starts[mid] <= offset
          lo = mid + 1
        else
          hi = mid
        end
      end
      i = lo - 1
      return true if i < 0
      Syntax.linkable_scope?(toks[i].scope)
    end

    # Nearest caret char offset at a pointer position (screen coords).
    # The column is found against MEASURED cell boundaries (binary
    # search, then snapped to the nearest edge).
    private def caret_at(inner : Egui::Rect, pos : Egui::Pos2,
                         v_off : Float64, h_off : Float64,
                         fonts : Egui::Fonts, font_size : Float64,
                         line_h : Float64, rope : Rope) : Int32
      y = pos.y - inner.min.y + v_off
      x = pos.x - inner.min.x + h_off
      line = (y / line_h).floor.to_i.clamp(0, rope.line_count - 1)
      text = rope.line_text(line)
      lo = 0
      hi = text.size
      while lo < hi
        mid = (lo + hi + 1) // 2
        if col_x(text, mid, fonts, font_size) <= x
          lo = mid
        else
          hi = mid - 1
        end
      end
      col = lo
      if col < text.size
        left = col_x(text, col, fonts, font_size)
        right = col_x(text, col + 1, fonts, font_size)
        col += 1 if x > (left + right) / 2.0 # past the cell midpoint
      end
      rope.offset_at(line, col)
    end

    # Word around `col` on a line for double-click selection (and the
    # go-to-definition word_at) — returns char columns
    # {start, end_exclusive} (same classes as TextArea).
    def self.word_range(text : String, pos : Int32) : {Int32, Int32}
      return {0, text.size} if text.empty?
      pos = pos.clamp(0, text.size - 1)
      l = pos
      while l > 0 && same_word_class?(text[l - 1], text[pos])
        l -= 1
      end
      r = pos
      while r < text.size - 1 && same_word_class?(text[r], text[r + 1])
        r += 1
      end
      {l, r + 1}
    end

    private def self.same_word_class?(a : Char, b : Char) : Bool
      word_char?(a) && word_char?(b) ||
        !word_char?(a) && !word_char?(b) && a == b
    end

    def self.word_char?(ch : Char) : Bool
      # `_` is part of an identifier: snake_case names (about_click,
      # word_char?) must survive as ONE word for the double-click
      # selection, the Ctrl-link scan and word_at's go-to-definition
      # lookup — splitting on the underscore left "about_click"
      # unresolved even though the index had it.
      ch.ascii_letter? || ch.ascii_number? || ch == '_'
    end
  end
end

# Ui helper — same shape as ui.textarea: build the widget, add it.
class Egui::Ui
  def code_editor(buffer : Kodkod::EditorBuffer, focus_id : String? = nil,
                  keyboard : Bool = true,
                  escape_clears_focus : Bool = true,
                  tab : String = "    ",
                  rows : Int32 = 25,
                  cursor_style : Symbol = :block,
                  cursor_blinks : Bool = true,
                  cursor_line : Bool = true,
                  syntax_highlight : Bool = true,
                  on_context_menu : (Egui::Ui ->)? = nil,
                  on_ctrl_click : (Int32 ->)? = nil,
                  link_lookup : (String -> Bool)? = nil) : Egui::Response
    add(Kodkod::CodeEditor.new(buffer, focus_id, keyboard,
      escape_clears_focus, tab, rows, cursor_style, cursor_blinks,
      cursor_line, syntax_highlight, on_context_menu, on_ctrl_click,
      link_lookup))
  end
end
