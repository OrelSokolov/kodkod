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
    # Context rows kept above (and below) the caret when the follow
    # pulls the view: the caret lands third from the top, not first.
    CONTEXT_ROWS =          2
    ID_PREFIX    = "kodkod/code_editor/"
    FONT_MIN     = 8.0
    FONT_MAX     = 40.0

    def initialize(@buffer : EditorBuffer, @focus_id : String? = nil,
                   @keyboard : Bool = true,
                   @escape_clears_focus : Bool = true,
                   @tab : String = "  ", @rows : Int32 = 25,
                   @cursor_style : Symbol = :block,
                   @cursor_blinks : Bool = true,
                   @cursor_line : Bool = true)
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
      scroll_id = id.child(SCROLL_SALT)
      vel_id = scroll_id.child(3)
      # State cells with no #interact call of their own must be marked
      # used or end-frame pruning drops them: the sticky column, the
      # metrics the class API (scroll_to_line) reads, and the running
      # max line width would all reset every frame.
      memory.use_id(anchor_id)
      memory.use_id(col_id)
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

      digits = {lines.to_s.size, 3}.max
      gutter_w = digits.to_f64 * char_w + GUTTER_PAD * 2.0
      inner = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + gutter_w, rect.top),
        Egui::Vec2.new({rect.width - gutter_w - BAR_W, char_w}.max, rect.height))
      view_h = inner.height
      view_w = inner.width
      memory.data.set_f64(id.child(LINE_H_SALT), line_h)
      memory.data.set_f64(id.child(VIEW_H_SALT), view_h)

      content_h = lines.to_f64 * line_h
      max_offset = {content_h - view_h, 0.0}.max

      # Running max line width (content width for the horizontal
      # scrollbar), reset per buffer version — only laid-out lines
      # contribute, so it grows as the user scrolls long lines past.
      wm_ver = id.child(WMAXV_SALT)
      wm_id = id.child(WMAX_SALT)
      if memory.data.get_int(wm_ver, -1) != rope.version
        memory.data.set_int(wm_ver, rope.version)
        memory.data.set_f64(wm_id, 0.0)
      end
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
          h_off -= input.scroll.y * char_w * 3.0
          kin.takeover
        else
          kin.input(input.scroll.y * style.scroll_speed, input.time,
            max_offset)
        end
      else
        kin.glide(input.dt, max_offset, ui.ctx)
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
      anchor = memory.data.get_int(anchor_id, -1)
      edited = false

      # --- mouse: click places the caret, drag selects ----------------
      if response.pressed? || response.clicked?
        response.request_focus
        if (pos = input.pointer_pos)
          at = caret_at(inner, pos, v_off, h_off, fonts, font_size, line_h, rope)
          if response.double_clicked?
            line, _col = rope.line_col_of(at)
            w0, w1 = word_range(rope.line_text(line), at - rope.line_start(line))
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
        cursor, anchor, edited = handle_keyboard(ui.ctx, cursor, anchor,
          view_h, line_h, col_id)
        ui.ctx.request_repaint if @cursor_blinks # caret blink
      end
      cursor = cursor.clamp(0, rope.size)
      anchor = -1 if anchor > rope.size

      # --- follow the caret -------------------------------------------
      if edited || cursor != cursor_prev
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
        h_off = h_off.clamp(0.0, {wmax + char_w * 4.0 - view_w, 0.0}.max)
      end

      memory.data.set_int(id, cursor)
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
      spans = @buffer.token_spans
      rows = [] of Egui::Galley::Row
      (lv0...k1).each do |li|
        s = rope.line_start(li)
        text = rope.line_text(li)
        runs = [] of Egui::Galley::RowRun
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
          while i < toks.size && starts[i] < line_end
            tok_s = {starts[i], s}.max
            tok_e = {starts[i + 1], line_end}.min
            if tok_e > tok_s
              frag = text[tok_s - s...tok_e - s]
              color = Syntax::Palette.color(toks[i].scope, visuals.dark)
              runs << Egui::Galley::RowRun.new(frag,
                col_x(text, tok_s - s, fonts, font_size), font_size, color, false)
            end
            i += 1
          end
          runs << Egui::Galley::RowRun.new("", 0.0, font_size, nil, false) if runs.empty?
        else
          runs << Egui::Galley::RowRun.new(text, 0.0, font_size, nil, false)
        end
        w = col_x(text, text.size, fonts, font_size)
        rows << Egui::Galley::Row.new(runs, w, line_h, li.to_f64 * line_h,
          row_ascent, li > 0)
        wmax = {wmax, w}.max
      end
      memory.data.set_f64(wm_id, wmax)
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
      # saturated selection blue. Suppressed in VIM mode
      # (cursor_line: false) — vim highlights the caret cell, not the
      # whole line.
      if @cursor_line
        cl_y = inner.min.y + cursor_line.to_f64 * line_h - v_off
        if cl_y >= inner.min.y - line_h && cl_y < inner.max.y
          painter.rect(Egui::Rect.from_min_size(
            Egui::Pos2.new(inner.min.x, cl_y),
            Egui::Vec2.new(inner.width, line_h)), 0.0,
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

      # Caret while focused; it BLINKS unless `cursor_blinks: false`
      # holds it steady (VIM's cursor never blinks).
      # :block (VIM normal/visual) fills
      # the character's MEASURED cell (the font's real advance — a
      # col*char_w grid drifts as fallback glyphs advance differently)
      # and re-draws the character under it in the editor background
      # (inverse video); :bar (VIM insert) is a thin bar at the cell's
      # left edge.
      if response.has_focus? &&
         (@cursor_blinks ? (input.time % 1.0) < 0.6 : true)
        line, col = rope.line_col_of(cursor)
        text = rope.line_text(line)
        x = inner.min.x + col_x(text, col, fonts, font_size) - h_off
        y = inner.min.y + line.to_f64 * line_h - v_off
        if @cursor_style == :bar
          painter.rect(Egui::Rect.from_min_size(Egui::Pos2.new(x, y + 1.0),
            Egui::Vec2.new(2.0, line_h - 2.0)), 0.0, visuals.text_color)
        else
          w = col_x(text, col + 1, fonts, font_size) -
              col_x(text, col, fonts, font_size)
          w = fonts.measure(" ", font_size).x if w <= 0.0 # EOL cell
          painter.rect(Egui::Rect.from_min_size(Egui::Pos2.new(x, y + 1.0),
            Egui::Vec2.new(w, line_h - 2.0)), 0.0, visuals.text_color)
          if (ch = text[col]?)
            painter.text(Egui::Pos2.new(x, y + line_h / 2.0),
              ch.to_s, font_size, visuals.window_fill, family: "monospace")
          end
        end
      end

      painter.clip = outer_clip

      # Gutter numbers (center-y text positions like TreeView rows).
      num_color = visuals.fade_color(visuals.text_color, 0.5)
      (lv0...k1).each do |li|
        y = rect.top + li.to_f64 * line_h - v_off + line_h / 2.0
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

    # Word around `col` on a line for double-click selection — returns
    # char columns {start, end_exclusive} (same classes as TextArea).
    private def word_range(text : String, pos : Int32) : {Int32, Int32}
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

    private def same_word_class?(a : Char, b : Char) : Bool
      word_char?(a) && word_char?(b) ||
        !word_char?(a) && !word_char?(b) && a == b
    end

    private def word_char?(ch : Char) : Bool
      ch.ascii_letter? || ch.ascii_number?
    end
  end
end

# Ui helper — same shape as ui.textarea: build the widget, add it.
class Egui::Ui
  def code_editor(buffer : Kodkod::EditorBuffer, focus_id : String? = nil,
                  keyboard : Bool = true,
                  escape_clears_focus : Bool = true,
                  tab : String = "  ",
                  rows : Int32 = 25,
                  cursor_style : Symbol = :block,
                  cursor_blinks : Bool = true,
                  cursor_line : Bool = true) : Egui::Response
    add(Kodkod::CodeEditor.new(buffer, focus_id, keyboard,
      escape_clears_focus, tab, rows, cursor_style, cursor_blinks,
      cursor_line))
  end
end
