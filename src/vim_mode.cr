# kodkod — VimMode: a VIM modal input layer driving CodeEditor.
#
# The editor widget renders with `keyboard: false` while a mode other
# than insert is active — this layer reads ctx.input itself and drives
# the caret/selection through CodeEditor's class API (cursor, edits,
# scroll). Insert mode hands the keyboard back to the widget; Escape
# is consumed HERE (`escape_clears_focus: false` on the widget) so it
# means "back to normal", never "drop focus".
#
# Scope: the basic vim toolkit — modes (normal/insert/visual v/V/
# command), counts (3j, 2dd), motions (h j k l w b e 0 ^ $ gg G
# f/F/t/T, Ctrl-d/u), operators (x r dd dw d$ D cc cw yy p P u), visual
# selection (v charwise, V linewise; motions extend it, d/y/c operate,
# o swaps the ends), and the `:` command line, executed by
# VimCommand::Runner (:w :q :wq :tabnew :{n} …). One unnamed register
# (the system clipboard). '/' search (literal pattern, wrap-around,
# n/N repeat, '?' backwards) shares the ':' line machinery. Text
# objects, macros, :s — future work.

require "./code_editor"
require "./vim_command"

module Kodkod
  class VimMode
    enum Mode
      Normal
      Insert
      Visual
      Command # typing after ':' (or '/'/'?') in normal mode
    end

    property mode : Mode = Mode::Normal
    # Pending keystrokes: a count ("3"), an operator ("d", "y", "c"),
    # a find prefix ("2f"), or the "g" of "gg".
    property pending : String = ""
    property command : String = "" # the ':'/'/' line being typed
    # The prompt of the line being typed: ':' runs a command, '/'/'?'
    # run a search. Plus the last executed search — the pattern and
    # direction that n/N repeat (an empty '/' line reuses it, vim).
    property line_prompt : Char = ':'
    property search_pattern : String = ""
    property? search_fwd : Bool = true
    # Visual mode: the linewise submode (V) and the RAW anchor offset.
    # The anchor lives vim-side — in linewise mode the widget's
    # caret/anchor cells are published at LINE BOUNDARIES (so the
    # widget paints whole lines), and the raw end is what `o` swaps
    # and line-range operators read.
    property? visual_line : Bool = false
    property visual_anchor : Int32 = 0
    property? enabled : Bool = true

    # The ':' command registry (see vim_command.cr): editor builtins
    # register themselves; the app registers its tab/file commands.
    property commands : VimCommand::Runner = VimCommand::Runner.new

    def reset : Nil
      @mode = Mode::Normal
      @pending = ""
      @command = ""
      @line_prompt = ':'
      @visual_line = false
      @visual_anchor = 0
    end

    def status_label : String
      case @mode
      when .insert?  then "-- INSERT --"
      when .visual?  then @visual_line ? "-- VISUAL LINE --" : "-- VISUAL --"
      when .command? then @line_prompt == ':' ? "-- COMMAND --" : "-- SEARCH --"
      else                 "-- NORMAL --"
      end
    end

    # The `keyboard:` flag the editor widget should render with.
    def widget_keyboard : Bool
      !@enabled || @mode.insert?
    end

    # The caret shape the editor widget should render with: a block in
    # every mode but insert (VIM's normal-mode cursor), a thin bar in
    # insert (VIM's insert cursor between characters) — and a bar too
    # when VIM is off (the standard editor caret).
    def cursor_style : Symbol
      @enabled && !@mode.insert? ? :block : :bar
    end

    # Process this frame's input for `focus_id` against `buffer`.
    # Returns true when anything changed (mode/cursor/text).
    def handle(ctx : Egui::Context, buffer : EditorBuffer,
               focus_id : String) : Bool
      return false unless @enabled
      return false unless ctx.memory.focus.has_focus?(
        CodeEditor.widget_id(focus_id))

      case @mode
      when .insert?  then handle_insert(ctx, buffer, focus_id)
      when .command? then handle_command(ctx, buffer, focus_id)
      when .visual?  then handle_visual(ctx, buffer, focus_id)
      else                handle_normal(ctx, buffer, focus_id)
      end
    end

    # --- insert mode: only Escape is ours ------------------------------

    private def handle_insert(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String) : Bool
      if ctx.input.consume_key(Egui::KeyCode::Escape)
        @mode = Mode::Normal
        # Leaving insert, the caret steps LEFT (vim: it sits ON the
        # last typed char, not after it).
        cur = CodeEditor.cursor_offset(ctx, focus_id)
        cur -= 1 if cur > 0
        CodeEditor.set_cursor_offset(ctx, buffer, focus_id, cur)
        true
      else
        false
      end
    end

    # --- normal mode -----------------------------------------------------

    # Normal mode processes EVERY command char of this frame's text
    # input in order — fast typing can batch two keys into one frame
    # ("dd" typed quickly would otherwise eat only the first 'd').
    # The loop breaks on a mode change (insert/command/visual): the
    # remaining chars belong to the new mode, and the widget rendered
    # this frame with keyboard: false, so they drop (an acceptable
    # corner — a mode switch mid-frame is a fast typist's edge case).
    private def handle_normal(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String) : Bool
      input = ctx.input

      # Escape cancels a half-typed prefix (2f…, 3r…) — a plain Escape
      # with nothing pending stays untouched (no-op in normal mode).
      if !@pending.empty? && input.consume_key(Egui::KeyCode::Escape)
        @pending = ""
        return true
      end

      # A selection in normal mode is MOUSE-made (the widget keyboard
      # — shift+arrows — is off here, and every motion collapses the
      # anchor). The standard-editor keys then honor the drag
      # directly, like gvim's clipboard behavior for mouse
      # selections: Ctrl+C/X/V and Delete/Backspace operate on it.
      if (sel = CodeEditor.selection(ctx, focus_id))
        if input.modifiers.ctrl && input.consume_key(Egui::KeyCode::C)
          Egui::SystemPorts::Clipboard.text =
            buffer.rope.slice(sel[0], sel[1] - sel[0])
          return true
        end
        if input.modifiers.ctrl && input.consume_key(Egui::KeyCode::X)
          Egui::SystemPorts::Clipboard.text =
            buffer.rope.slice(sel[0], sel[1] - sel[0])
          CodeEditor.delete_chars(ctx, buffer, focus_id,
            sel[0], sel[1] - sel[0])
          return true
        end
        if input.modifiers.ctrl && input.consume_key(Egui::KeyCode::V) &&
           (paste = Egui::SystemPorts::Clipboard.text)
          CodeEditor.replace_range(ctx, buffer, focus_id,
            sel[0], sel[1] - sel[0], paste.gsub(/\r\n|\r/, "\n"))
          return true
        end
        if input.consume_key(Egui::KeyCode::Delete) ||
           (!input.modifiers.ctrl && input.consume_key(Egui::KeyCode::Backspace))
          CodeEditor.delete_chars(ctx, buffer, focus_id,
            sel[0], sel[1] - sel[0])
          return true
        end
      end

      # Ctrl combos: only Ctrl-d/u (half page) are ours; the rest
      # (Ctrl+s, Ctrl+o, …) belong to the app's hotkeys.
      if input.modifiers.ctrl
        down = input.consume_key(Egui::KeyCode::D)
        up = input.consume_key(Egui::KeyCode::U)
        return false unless down || up
        jump_half_page(ctx, buffer, focus_id, down ? 1 : -1)
        return true
      end

      acted = false
      chars = input.text.chars
      i = 0
      while i < chars.size
        ch = chars[i]
        i += 1

        # An "r" prefix (3r…) takes ANY char as its replacement.
        if (m = @pending.match(/\A(\d*)r\z/))
          unless ch == '\n' # r<CR> is a line split in vim — cancel quietly
            count_s = m[1]? || ""
            replace_chars(ctx, buffer, focus_id, ch,
              count_s.empty? ? 1 : count_s.to_i)
          end
          @pending = ""
          acted = true
          break unless @mode.normal?
          next
        end

        # A find prefix (2f…) takes ANY char as its target.
        if (m = @pending.match(/\A(\d*)([fFtT])\z/))
          if command_char?(ch) || !@pending.empty?
            count_s = m[1]? || ""
            find_in_line(ctx, buffer, focus_id, m[2].not_nil![0], ch,
              count_s.empty? ? 1 : count_s.to_i)
            @pending = ""
            acted = true
            break unless @mode.normal?
            next
          end
        end

        next unless command_char?(ch)
        acted = true

        # Count prefix. A bare "0" (no digits pending) is the motion
        # "line start", not a count.
        if ch.number? && !(ch == '0' && !@pending.matches?(/\A\d/))
          @pending += ch if @pending.size < 4
          next
        end
        count = @pending[/\A\d+/]?.try(&.to_i) || 1
        op = @pending[/[dyc]/]?

        case ch
        when 'i', 'I', 'a', 'A', 'o', 'O'
          enter_insert(ctx, buffer, focus_id, ch)
          @pending = ""
        when 'v' then enter_visual(ctx, buffer, focus_id, linewise: false)
        when 'V' then enter_visual(ctx, buffer, focus_id, linewise: true)
        when 'h', 'j', 'k', 'l', 'w', 'b', 'e', '0', '^', '$', 'G', ' '
          motion = ch == ' ' ? 'l' : ch
          if op
            apply_operator_motion(ctx, buffer, focus_id,
              op.not_nil![0], motion, count)
          else
            apply_motion(ctx, buffer, focus_id, motion, count)
          end
          @pending = ""
        when 'g'
          if @pending == "g"
            apply_motion(ctx, buffer, focus_id, 'G', 1, to_line: 0)
            @pending = ""
          else
            @pending = "g"
          end
        when 'd', 'y', 'c'
          if op == ch.to_s # dd / yy / cc — line-wise
            line = CodeEditor.cursor(ctx, buffer, focus_id)[0]
            apply_operator_lines(ctx, buffer, focus_id, ch, line, count)
            @pending = ""
          elsif op
            @pending = "" # "dy" etc. — nonsense, reset silently
          else
            @pending = "#{@pending[/\A\d+/]?}#{ch}"
          end
        when 'x'
          delete_chars_at_caret(ctx, buffer, focus_id, count)
          @pending = ""
        when 'D'
          delete_to_eol(ctx, buffer, focus_id)
          @pending = ""
        when 'p', 'P'
          paste(ctx, buffer, focus_id, after: ch == 'p', count: count)
          @pending = ""
        when 'u'
          CodeEditor.undo(ctx, buffer, focus_id)
          @pending = ""
        when 'f', 'F', 't', 'T', 'r'
          @pending += ch
        when ':', '/', '?'
          @mode = Mode::Command
          @line_prompt = ch
          @command = chars[i..].join # rest of THIS frame feeds the line
          @commands.clear_message   # the line replaces the last message
          @pending = ""
          i = chars.size
        when 'n'
          search_jump(ctx, buffer, focus_id, @search_fwd, count)
          @pending = ""
        when 'N'
          search_jump(ctx, buffer, focus_id, !@search_fwd, count)
          @pending = ""
        else
          # Unknown command: clear pending (vim beeps; we reset
          # quietly) and keep the rest of the frame's chars.
          @pending = ""
        end

        break unless @mode.normal?
      end
      acted
    end

    # --- visual mode ------------------------------------------------------

    private def enter_visual(ctx : Egui::Context, buffer : EditorBuffer,
                             focus_id : String, linewise : Bool) : Nil
      @mode = Mode::Visual
      @visual_line = linewise
      @visual_anchor = CodeEditor.cursor_offset(ctx, focus_id)
      @pending = ""
      publish_visual(ctx, buffer, focus_id)
    end

    private def exit_visual(ctx : Egui::Context, buffer : EditorBuffer,
                            focus_id : String) : Nil
      @mode = Mode::Normal
      @visual_line = false
      @pending = ""
      cur = CodeEditor.cursor_offset(ctx, focus_id)
      CodeEditor.set_cursor_offset(ctx, buffer, focus_id, cur)
    end

    # Push the visual selection into the widget's cells. Charwise: the
    # raw anchor. Linewise: both ends at LINE BOUNDARIES so the widget
    # paints whole lines.
    private def publish_visual(ctx : Egui::Context, buffer : EditorBuffer,
                               focus_id : String) : Nil
      caret = CodeEditor.cursor_offset(ctx, focus_id)
      unless @visual_line
        CodeEditor.set_selection(ctx, focus_id, caret, @visual_anchor)
        return
      end
      rope = buffer.rope
      al = rope.line_of(@visual_anchor)
      cl = rope.line_of(caret)
      if cl >= al
        # caret at/below the anchor: caret → its line END, anchor →
        # the top line START.
        CodeEditor.set_selection(ctx, focus_id,
          rope.offset_at(cl, rope.line_length(cl)), rope.line_start(al))
      else
        # caret ABOVE the anchor: caret → its line START (so the next
        # up-motion reads it), anchor → the bottom line END.
        CodeEditor.set_selection(ctx, focus_id,
          rope.line_start(cl), rope.offset_at(al, rope.line_length(al)))
      end
    end

    # The raw (pre-boundary) visual range: the vim-side anchor and the
    # caret, min/max — linewise operators expand it to full lines.
    private def visual_raw_range(ctx : Egui::Context,
                                 focus_id : String) : {Int32, Int32}
      caret = CodeEditor.cursor_offset(ctx, focus_id)
      {Math.min(caret, @visual_anchor), Math.max(caret, @visual_anchor)}
    end

    # Visual operators: charwise covers the inclusive selection (a
    # zero-width one still eats the char under the caret, like vim's
    # `v d`); linewise expands to whole lines and reuses the line-wise
    # operator (dd/cc/yy semantics, newline included).
    private def visual_delete(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String, change : Bool = false) : Nil
      rope = buffer.rope
      if @visual_line
        lo, hi = visual_raw_range(ctx, focus_id)
        l0 = rope.line_of(lo)
        apply_operator_lines(ctx, buffer, focus_id, change ? 'c' : 'd',
          l0, rope.line_of(hi) - l0 + 1)
      else
        caret = CodeEditor.cursor_offset(ctx, focus_id)
        sel = inclusive_selection(ctx, buffer, focus_id) ||
              {caret, {caret + 1, rope.size}.min}
        operate_range(ctx, buffer, focus_id, change ? 'c' : 'd',
          sel[0], sel[1])
      end
    end

    private def visual_yank(ctx : Egui::Context, buffer : EditorBuffer,
                            focus_id : String) : Nil
      rope = buffer.rope
      if @visual_line
        lo, hi = visual_raw_range(ctx, focus_id)
        l0 = rope.line_of(lo)
        apply_operator_lines(ctx, buffer, focus_id, 'y', l0,
          rope.line_of(hi) - l0 + 1)
      else
        caret = CodeEditor.cursor_offset(ctx, focus_id)
        sel = inclusive_selection(ctx, buffer, focus_id) ||
              {caret, {caret + 1, rope.size}.min}
        Egui::SystemPorts::Clipboard.text =
          rope.slice(sel[0], sel[1] - sel[0])
        # The caret lands on the START of the yanked text (vim).
        CodeEditor.set_cursor_offset(ctx, buffer, focus_id, sel[0])
      end
    end

    private def handle_visual(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String) : Bool
      input = ctx.input
      if input.consume_key(Egui::KeyCode::Escape)
        exit_visual(ctx, buffer, focus_id)
        return true
      end

      # The standard-editor reflexes on the visual selection:
      # Ctrl+C yanks, Ctrl+X cuts (vim's own y/d stay as they are).
      if input.modifiers.ctrl
        if input.consume_key(Egui::KeyCode::C)
          visual_yank(ctx, buffer, focus_id)
          exit_visual(ctx, buffer, focus_id)
          return true
        end
        if input.consume_key(Egui::KeyCode::X)
          visual_delete(ctx, buffer, focus_id)
          exit_visual(ctx, buffer, focus_id)
          return true
        end
      end

      acted = false
      chars = input.text.chars
      i = 0
      while i < chars.size
        ch = chars[i]
        i += 1
        next unless command_char?(ch)
        acted = true

        # Count prefix, like normal mode (a bare "0" is the motion).
        if ch.number? && !(ch == '0' && !@pending.matches?(/\A\d/))
          @pending += ch if @pending.size < 4
          next
        end
        count = @pending[/\A\d+/]?.try(&.to_i) || 1

        case ch
        when 'h', 'l', 'w', 'b', 'e', '0', '^', '$', 'j', 'k'
          apply_motion(ctx, buffer, focus_id, ch, count, extend_sel: true)
          publish_visual(ctx, buffer, focus_id)
          @pending = ""
        when 'G'
          apply_motion(ctx, buffer, focus_id, 'G', count, extend_sel: true)
          publish_visual(ctx, buffer, focus_id)
          @pending = ""
        when 'g'
          if @pending == "g"
            apply_motion(ctx, buffer, focus_id, 'G', 1, to_line: 0,
              extend_sel: true)
            publish_visual(ctx, buffer, focus_id)
            @pending = ""
          else
            @pending = "g"
          end
        when 'o' # swap the selection ends
          caret = CodeEditor.cursor_offset(ctx, focus_id)
          old_anchor = @visual_anchor
          @visual_anchor = caret
          CodeEditor.set_cursor_offset(ctx, buffer, focus_id, old_anchor,
            extend_sel: true)
          publish_visual(ctx, buffer, focus_id)
        when 'd', 'x'
          visual_delete(ctx, buffer, focus_id)
          exit_visual(ctx, buffer, focus_id)
        when 'y'
          visual_yank(ctx, buffer, focus_id)
          exit_visual(ctx, buffer, focus_id)
        when 'c'
          visual_delete(ctx, buffer, focus_id, change: true)
          @visual_line = false # operate_range switched to insert
        when 'v'
          if @visual_line # linewise → charwise, keep the endpoints
            @visual_line = false
            publish_visual(ctx, buffer, focus_id)
          else
            exit_visual(ctx, buffer, focus_id)
          end
        when 'V'
          if @visual_line
            exit_visual(ctx, buffer, focus_id)
          else
            @visual_line = true
            publish_visual(ctx, buffer, focus_id)
          end
        else
          # Unknown command: drop pending quietly, keep the rest.
          @pending = ""
        end

        break unless @mode.visual?
      end
      acted
    end

    # --- ':' command line --------------------------------------------------

    private def handle_command(ctx : Egui::Context, buffer : EditorBuffer,
                               focus_id : String) : Bool
      input = ctx.input
      if input.consume_key(Egui::KeyCode::Escape)
        @mode = Mode::Normal
        @command = ""
        return true
      end
      if input.consume_key(Egui::KeyCode::Enter)
        if @line_prompt == ':'
          run_command(ctx, buffer, focus_id, @command.strip)
        else
          run_search(ctx, buffer, focus_id, @command,
            forward: @line_prompt == '/')
        end
        @mode = Mode::Normal
        @command = ""
        return true
      end
      if input.consume_key(Egui::KeyCode::Backspace)
        if @command.empty? # backspacing an empty line leaves it, like vim
          @mode = Mode::Normal
        else
          @command = @command[0...-1]
        end
        return true
      end
      unless input.text.empty?
        @command += input.text.gsub('\n', "")
        return true
      end
      false
    end

    # Execute a finished ':' line — parsing, resolution, warnings, and
    # feedback all live in the VimCommand layer (see vim_command.cr).
    private def run_command(ctx : Egui::Context, buffer : EditorBuffer,
                            focus_id : String, cmd : String) : Nil
      @commands.run(ctx, buffer, focus_id, cmd)
    end

    # --- '/' and '?' search -------------------------------------------------

    # A literal string search (vim's plain /pattern without magic).
    # run_search stores the pattern/direction for n/N (an empty line
    # reuses the last pattern, like vim); search_jump moves.
    private def run_search(ctx : Egui::Context, buffer : EditorBuffer,
                           focus_id : String, pattern : String,
                           forward : Bool) : Nil
      unless pattern.empty?
        @search_pattern = pattern
        @search_fwd = forward
      end
      search_jump(ctx, buffer, focus_id, @search_fwd, 1)
    end

    # Jump to the count-th match from the caret (wrapscan wraps at the
    # buffer ends); E486 when not found, E35 when nothing was ever
    # searched. Feedback rides the command bar like the E-messages.
    private def search_jump(ctx : Egui::Context, buffer : EditorBuffer,
                            focus_id : String, forward : Bool,
                            count : Int32) : Nil
      if @search_pattern.empty?
        @commands.last_message = VimCommand::Message.new(
          VimCommand::Kind::Error, "E35: No previous regular expression")
        return
      end
      text = buffer.rope.to_s
      pat = @search_pattern
      cur = CodeEditor.cursor_offset(ctx, focus_id)
      at = -1
      count.times do
        at = search_step(text, pat, cur, forward)
        break if at < 0
        cur = at
      end
      if at < 0
        @commands.last_message = VimCommand::Message.new(
          VimCommand::Kind::Error, "E486: Pattern not found: #{pat}")
        return
      end
      @commands.clear_message
      line, col = buffer.rope.line_col_of(at)
      CodeEditor.set_cursor_offset(ctx, buffer, focus_id, at)
      set_desired_col(ctx, focus_id, col)
      CodeEditor.scroll_to_line(ctx, buffer, focus_id, line)
    end

    # One step from `cur`: the nearest match strictly after the caret
    # (forward) or the nearest match ending at/before the caret
    # (backward) — a match covering the caret never counts — wrapping
    # at the buffer ends. Match START offset, or -1.
    private def search_step(text : String, pat : String, cur : Int32,
                            forward : Bool) : Int32
      if forward
        return -1 if pat.empty?
        from = {cur + 1, text.size}.min
        text.index(pat, from) || text.index(pat, 0) || -1
      else
        hi = cur - pat.size # a match may START no later than this
        return -1 if hi < 0 || pat.empty?
        text.rindex(pat, hi) || text.rindex(pat) || -1
      end
    end

    # --- motions -------------------------------------------------------------

    # The sticky column lives in the WIDGET's COL cell (single source
    # of truth: the widget's own up/down and vim's motions share it).
    private def desired_col(ctx : Egui::Context, focus_id : String,
                            current : Int32) : Int32
      ctx.memory.data.get_int(
        CodeEditor.widget_id(focus_id).child(CodeEditor::COL_SALT), current)
    end

    private def set_desired_col(ctx : Egui::Context, focus_id : String,
                                col : Int32) : Nil
      ctx.memory.data.set_int(
        CodeEditor.widget_id(focus_id).child(CodeEditor::COL_SALT), col)
    end

    # Move the caret; `extend_sel: true` grows the selection (visual
    # mode).
    private def apply_motion(ctx : Egui::Context, buffer : EditorBuffer,
                             focus_id : String, ch : Char, count : Int32 = 1,
                             extend_sel : Bool = false,
                             to_line : Int32? = nil) : Nil
      rope = buffer.rope
      off = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(off)

      target = case ch
      when 'h' then rope.offset_at(line, {col - count, 0}.max)
      when 'l' then rope.offset_at(line, {col + count, rope.line_length(line)}.min)
      when 'j', 'k'
        # Display-row stepping (fold-aware): j over a folded header
        # lands on the next VISIBLE line, not an invisible body line.
        nl = CodeEditor.vertical_line(ctx, buffer, focus_id, line,
          ch == 'j' ? count : -count)
        rope.offset_at(nl, {desired_col(ctx, focus_id, col), rope.line_length(nl)}.min)
      when 'w' then word_motion(rope, off, count, forward: true)
      when 'b' then word_motion(rope, off, count, forward: false)
      when 'e' then end_motion(rope, off, count)
      when '0' then rope.offset_at(line, 0)
      when '^' then rope.offset_at(line, first_non_blank(rope, line))
      when '$' then rope.offset_at(line, rope.line_length(line))
      when 'G'
        l = to_line || (count > 1 ? count - 1 : rope.line_count - 1)
        l = {l, rope.line_count - 1}.min
        rope.offset_at(l, {desired_col(ctx, focus_id, col), rope.line_length(l)}.min)
      else off
      end

      case ch
      when 'h', 'l', 'w', 'b', 'e', '0', '^', '$'
        set_desired_col(ctx, focus_id, rope.line_col_of(target)[1])
      end

      CodeEditor.set_cursor_offset(ctx, buffer, focus_id, target,
        extend_sel: extend_sel)
      CodeEditor.scroll_to_line(ctx, buffer, focus_id, rope.line_of(target))
    end

    private def jump_half_page(ctx : Egui::Context, buffer : EditorBuffer,
                               focus_id : String, dir : Int32) : Nil
      id = CodeEditor.widget_id(focus_id)
      line_h = ctx.memory.data.get_f64(id.child(CodeEditor::LINE_H_SALT), 20.0)
      view_h = ctx.memory.data.get_f64(id.child(CodeEditor::VIEW_H_SALT), 400.0)
      half = {(view_h / line_h / 2.0).floor.to_i, 1}.max
      line = CodeEditor.cursor(ctx, buffer, focus_id)[0]
      nl = CodeEditor.vertical_line(ctx, buffer, focus_id, line, dir * half)
      apply_motion(ctx, buffer, focus_id, 'G', 1, to_line: nl)
    end

    # `w`/`b`: word starts. Three char classes — whitespace (0), word
    # ([A-Za-z0-9_], 1), punctuation (2) — a motion stops at every
    # class boundary, like vim.
    private def char_class(rope : Rope, off : Int32) : Int32
      return 0 if off < 0 || off >= rope.size
      c = rope.char_at(off)
      return 0 if c.ascii_whitespace?
      c.ascii_letter? || c.ascii_number? || c == '_' ? 1 : 2
    end

    private def word_motion(rope : Rope, off : Int32, count : Int32,
                            forward : Bool) : Int32
      pos = off
      count.times do
        if forward
          cls = char_class(rope, pos)
          while pos < rope.size && char_class(rope, pos) == cls
            pos += 1
          end
          while pos < rope.size && char_class(rope, pos).zero?
            pos += 1
          end
        else
          pos -= 1
          while pos > 0 && char_class(rope, pos).zero?
            pos -= 1
          end
          cls = char_class(rope, pos)
          while pos > 0 && char_class(rope, pos - 1) == cls
            pos -= 1
          end
        end
      end
      pos.clamp(0, rope.size)
    end

    # `e`: end of the count-th word forward (caret ON the last char).
    private def end_motion(rope : Rope, off : Int32, count : Int32) : Int32
      return 0 if rope.size <= 1
      pos = off
      count.times do
        pos += 1
        while pos < rope.size - 1 && char_class(rope, pos).zero?
          pos += 1
        end
        cls = char_class(rope, pos)
        while pos + 1 < rope.size && char_class(rope, pos + 1) == cls
          pos += 1
        end
      end
      pos.clamp(0, rope.size - 1)
    end

    # f/F/t/T: find a char on the current line. `before` variants (t/T)
    # stop one short of the match.
    private def find_in_line(ctx : Egui::Context, buffer : EditorBuffer,
                             focus_id : String, cmd : Char, target : Char,
                             count : Int32) : Nil
      rope = buffer.rope
      off = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(off)
      text = rope.line_text(line)
      forward = cmd == 'f' || cmd == 't'

      idx = nil
      if forward
        i = col + 1
        hits = 0
        while i < text.size
          if text[i] == target
            hits += 1
            if hits == count
              idx = i
              break
            end
          end
          i += 1
        end
      else
        i = col - 1
        hits = 0
        while i >= 0
          if text[i] == target
            hits += 1
            if hits == count
              idx = i
              break
            end
          end
          i -= 1
        end
      end
      return unless idx

      idx -= 1 if cmd == 't' || cmd == 'T'
      idx = {idx, 0}.max
      CodeEditor.set_cursor(ctx, buffer, focus_id, line, idx)
      set_desired_col(ctx, focus_id, idx)
      CodeEditor.scroll_to_line(ctx, buffer, focus_id, line)
    end

    private def first_non_blank(rope : Rope, line : Int32) : Int32
      text = rope.line_text(line)
      i = 0
      while i < text.size && text[i].ascii_whitespace?
        i += 1
      end
      i
    end

    # --- operators --------------------------------------------------------------

    private def enter_insert(ctx : Egui::Context, buffer : EditorBuffer,
                             focus_id : String, ch : Char) : Nil
      rope = buffer.rope
      off = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(off)
      case ch
      when 'i' # stay where we are
      when 'I' then CodeEditor.set_cursor(ctx, buffer, focus_id, line, first_non_blank(rope, line))
      when 'a' then CodeEditor.set_cursor_offset(ctx, buffer, focus_id, {off + 1, rope.size}.min)
      when 'A' then CodeEditor.set_cursor(ctx, buffer, focus_id, line, rope.line_length(line))
      when 'o'
        CodeEditor.set_cursor(ctx, buffer, focus_id, line, rope.line_length(line))
        CodeEditor.insert_text(ctx, buffer, focus_id, "\n")
      when 'O'
        CodeEditor.set_cursor(ctx, buffer, focus_id, line, 0)
        CodeEditor.insert_text(ctx, buffer, focus_id, "\n")
      end
      @mode = Mode::Insert
    end

    # Operator + motion combos: dw, d$, db, cw, yw, … The operator
    # covers [caret, motion target) (or the reverse for backwards
    # motions).
    private def apply_operator_motion(ctx : Egui::Context,
                                      buffer : EditorBuffer, focus_id : String,
                                      op : Char, motion : Char,
                                      count : Int32) : Nil
      rope = buffer.rope
      cur = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(cur)

      case motion
      when 'j', 'k', 'G'
        # Line-wise by delegation.
        nl = case motion
             when 'j' then {line + count, rope.line_count - 1}.min
             when 'k' then {line - count, 0}.max
             else          (count > 1 ? count - 1 : rope.line_count - 1)
             end
        n = (line - nl).abs + 1
        apply_operator_lines(ctx, buffer, focus_id, op,
          {line, nl}.min, n)
        return
      end

      from = cur
      to = case motion
      when 'w'  then word_motion(rope, cur, count, forward: true)
      when 'b'  then word_motion(rope, cur, count, forward: false)
      when 'e'  then {end_motion(rope, cur, count) + 1, rope.size}.min
      when 'h'  then rope.offset_at(line, {col - count, 0}.max)
      when 'l'  then rope.offset_at(line, {col + count, rope.line_length(line)}.min)
      when '0'  then rope.offset_at(line, 0)
      when '^'  then rope.offset_at(line, first_non_blank(rope, line))
      when '$'  then rope.offset_at(line, rope.line_length(line))
      else return
      end

      # cw behaves like ce (vim quirk: it does not eat the trailing
      # whitespace), dw does.
      if op == 'c' && motion == 'w'
        to = {end_motion(rope, cur, count) + 1, rope.size}.min
      end
      # d$ includes the char under the caret's line end; nothing extra
      # needed — offset_at(len) is that position.

      from, to = {from, to}.min, {from, to}.max
      # `d h`/`d 0` delete BEFORE the caret: the min/max above already
      # handles direction.
      return if to <= from

      operate_range(ctx, buffer, focus_id, op, from, to)
    end

    # dd / yy / cc — line-wise, `count` lines from `line`.
    private def apply_operator_lines(ctx : Egui::Context,
                                     buffer : EditorBuffer, focus_id : String,
                                     op : Char, line : Int32,
                                     count : Int32) : Nil
      rope = buffer.rope
      l0 = {line, 0}.max
      l1 = {l0 + count - 1, rope.line_count - 1}.min
      ls = rope.line_start(l0)
      last = l1 + 1 >= rope.line_count
      to = last ? rope.line_start(l1) + rope.line_length(l1)
                : rope.line_start(l1 + 1)
      # The last line has no '\n' of its own after it: d eats the
      # newline BEFORE the range instead (vim joins up), otherwise an
      # empty last line could never be deleted at all.
      from = last && l0 > 0 && op == 'd' ? ls - 1 : ls
      # Line-wise register: the lines' text plus a trailing newline,
      # even at the file end — `p` detects linewise by the newline.
      reg = rope.slice(ls, to - ls)
      reg += "\n" unless reg.ends_with?('\n')

      if op == 'y'
        # Line-wise yank keeps the trailing newline; the caret stays.
        Egui::SystemPorts::Clipboard.text = reg
        CodeEditor.set_cursor(ctx, buffer, focus_id, l0, 0)
      else
        # Line-wise delete/change yanks with the newline; cc on an
        # empty line just enters insert (nothing to remove).
        if to > from
          Egui::SystemPorts::Clipboard.text = reg
          CodeEditor.delete_chars(ctx, buffer, focus_id, from, to - from)
        end
        nl = {l0, rope.line_count - 1}.min
        CodeEditor.set_cursor(ctx, buffer, focus_id, nl,
          first_non_blank(rope, nl))
        @mode = Mode::Insert if op == 'c'
      end
    end

    # Apply d/c/y over [from, to).
    private def operate_range(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String, op : Char, from : Int32,
                              to : Int32) : Nil
      rope = buffer.rope
      case op
      when 'y'
        Egui::SystemPorts::Clipboard.text = rope.slice(from, to - from)
        CodeEditor.set_cursor_offset(ctx, buffer, focus_id, from)
      when 'd', 'c'
        Egui::SystemPorts::Clipboard.text = rope.slice(from, to - from)
        CodeEditor.delete_chars(ctx, buffer, focus_id, from, to - from)
        CodeEditor.set_cursor_offset(ctx, buffer, focus_id, from)
        @mode = Mode::Insert if op == 'c'
      end
    end

    # x — delete `count` chars at the caret (or the selection).
    private def delete_chars_at_caret(ctx : Egui::Context,
                                      buffer : EditorBuffer, focus_id : String,
                                      count : Int32) : Nil
      if (sel = CodeEditor.selection(ctx, focus_id))
        delete_selection(ctx, buffer, focus_id, yank: true)
        return
      end
      rope = buffer.rope
      cur = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(cur)
      n = {count, rope.line_length(line) - col}.min
      n = {n, rope.size - cur}.min
      return if n <= 0
      Egui::SystemPorts::Clipboard.text = rope.slice(cur, n)
      CodeEditor.delete_chars(ctx, buffer, focus_id, cur, n)
    end

    # r{char} — replace `count` chars at the caret with `char`. Vim does
    # nothing (a beep) when fewer than `count` chars remain on the line;
    # the caret lands on the last replaced char.
    private def replace_chars(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String, ch : Char, count : Int32) : Nil
      rope = buffer.rope
      cur = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(cur)
      n = {count, rope.line_length(line) - col}.min
      return if n < count
      CodeEditor.replace_range(ctx, buffer, focus_id, cur, n, ch.to_s * n)
      CodeEditor.set_cursor_offset(ctx, buffer, focus_id, cur + n - 1)
    end

    private def delete_to_eol(ctx : Egui::Context, buffer : EditorBuffer,
                              focus_id : String) : Nil
      rope = buffer.rope
      cur = CodeEditor.cursor_offset(ctx, focus_id)
      line, col = rope.line_col_of(cur)
      len = rope.line_length(line)
      return if len <= col
      Egui::SystemPorts::Clipboard.text = rope.slice(cur, len - col)
      CodeEditor.delete_chars(ctx, buffer, focus_id, cur, len - col)
    end

    private def paste(ctx : Egui::Context, buffer : EditorBuffer,
                      focus_id : String, after : Bool, count : Int32) : Nil
      text = Egui::SystemPorts::Clipboard.text.to_s
      return if text.empty?
      rope = buffer.rope
      line = CodeEditor.cursor(ctx, buffer, focus_id)[0]

      if text.ends_with?('\n') # line-wise register
        count.times do
          at = after ? rope.offset_at({line + 1, rope.line_count - 1}.min, 0)
                     : rope.line_start(line)
          CodeEditor.replace_range(ctx, buffer, focus_id, at, 0, text)
          line += 1
          rope = buffer.rope # mutated
        end
      else # char-wise: after → past the caret, caret lands on last char
        at = CodeEditor.cursor_offset(ctx, focus_id)
        at += 1 if after && at < buffer.rope.size
        ins = text * count
        CodeEditor.replace_range(ctx, buffer, focus_id, at, 0, ins)
        CodeEditor.set_cursor_offset(ctx, buffer, focus_id,
          at + ins.size - 1)
      end
    end

    # Visual-mode selection is INCLUSIVE of both endpoints (vim):
    # the char under the caret belongs to the selection, so d/y cover
    # [min, max] — one char more than the widget's exclusive range.
    private def inclusive_selection(ctx : Egui::Context, buffer : EditorBuffer,
                                    focus_id : String) : {Int32, Int32}?
      if (sel = CodeEditor.selection(ctx, focus_id))
        to = {sel[1] + 1, buffer.rope.size}.min
        {sel[0], to}
      end
    end

    private def delete_selection(ctx : Egui::Context, buffer : EditorBuffer,
                                 focus_id : String, yank : Bool) : Nil
      if (sel = inclusive_selection(ctx, buffer, focus_id))
        if yank
          Egui::SystemPorts::Clipboard.text =
            buffer.rope.slice(sel[0], sel[1] - sel[0])
        end
        CodeEditor.delete_chars(ctx, buffer, focus_id, sel[0],
          sel[1] - sel[0])
      end
    end

    # Could this char start a vim command? InputState.text is
    # per-frame and nothing else consumes it while the widget renders
    # keyboard: false.
    private def command_char?(c : Char) : Bool
      c.ascii_letter? || c.number? || ":$^0/?".includes?(c)
    end
  end
end
