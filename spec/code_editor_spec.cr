require "spec"
require "../src/code_editor"

KSCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

def editor_frame(ctx : Egui::Context, buffer : Kodkod::EditorBuffer,
                 fid : String = "t1", keyboard : Bool = true,
                 cursor_style : Symbol = :block, rows : Int32 = 20,
                 events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(KSCREEN, events, time))
  ctx.central_panel do |ui|
    ui.code_editor(buffer, focus_id: fid, keyboard: keyboard, rows: rows,
      cursor_style: cursor_style)
  end
  ctx.end_frame
end

def center_click : Array(Egui::Event)
  pos = Egui::Pos2.new(400.0, 300.0)
  [Egui::Event.pointer_moved(pos),
   Egui::Event.pointer_pressed(pos),
   Egui::Event.pointer_released(pos)]
end

describe Kodkod::CodeEditor do
  it "renders and keeps the buffer untouched by a read-only frame" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("line one\nline two\n")
    3.times { |i| editor_frame(ctx, b, time: 0.016 * (i + 1)) }
    b.text.should eq("line one\nline two\n")
  end

  it "types text into the focused editor" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("")
    editor_frame(ctx, b) # render → the widget exists
    Kodkod::CodeEditor.request_focus(ctx, "t1")
    editor_frame(ctx, b) # focus lands
    editor_frame(ctx, b, events: [Egui::Event.text_input("hi")],
      time: 0.048)
    b.text.should eq("hi")
    Kodkod::CodeEditor.cursor_offset(ctx, "t1").should eq(2)
  end

  it "backspaces and moves the caret with arrow keys" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("abc")
    Kodkod::CodeEditor.request_focus(ctx, "t1")
    editor_frame(ctx, b)
    editor_frame(ctx, b, time: 0.032)
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "t1", 3)
    editor_frame(ctx, b,
      events: [Egui::Event.key_pressed(Egui::KeyCode::Backspace)],
      time: 0.048)
    b.text.should eq("ab")
    Kodkod::CodeEditor.cursor_offset(ctx, "t1").should eq(2) # line end
    editor_frame(ctx, b,
      events: [Egui::Event.key_pressed(Egui::KeyCode::Left)],
      time: 0.064)
    Kodkod::CodeEditor.cursor_offset(ctx, "t1").should eq(1)
    editor_frame(ctx, b,
      events: [Egui::Event.key_pressed(Egui::KeyCode::Left)],
      time: 0.08)
    Kodkod::CodeEditor.cursor_offset(ctx, "t1").should eq(0)
  end

  it "supports Enter with auto-indent and Tab insert" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("  def foo")
    Kodkod::CodeEditor.request_focus(ctx, "t1")
    editor_frame(ctx, b)
    editor_frame(ctx, b, time: 0.032)
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "t1", 9) # line end
    editor_frame(ctx, b,
      events: [Egui::Event.key_pressed(Egui::KeyCode::Enter)],
      time: 0.048)
    b.text.should eq("  def foo\n  ")
  end

  it "undoes and redoes through the class API" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("")
    Kodkod::CodeEditor.insert_text(ctx, b, "t1", "hello")
    b.text.should eq("hello")
    Kodkod::CodeEditor.undo(ctx, b, "t1").should be_true
    b.text.should eq("")
    Kodkod::CodeEditor.redo(ctx, b, "t1").should be_true
    b.text.should eq("hello")
  end

  it "maps cursor line/col and selections" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("ab\ncd")
    Kodkod::CodeEditor.set_cursor(ctx, b, "t1", 1, 1)
    Kodkod::CodeEditor.cursor(ctx, b, "t1").should eq({1, 1})
    Kodkod::CodeEditor.cursor_offset(ctx, "t1").should eq(4) # a b \n c d
    Kodkod::CodeEditor.selection(ctx, "t1").should be_nil

    Kodkod::CodeEditor.set_selection(ctx, "t1", 0, 2)
    Kodkod::CodeEditor.selection(ctx, "t1").should eq({0, 2})
    Kodkod::CodeEditor.selection_text(ctx, b, "t1").should eq("ab")
  end

  it "replace_range drives the buffer and the caret" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("hello world")
    Kodkod::CodeEditor.replace_range(ctx, b, "t1", 0, 5, "goodbye")
    b.text.should eq("goodbye world")
    Kodkod::CodeEditor.cursor_offset(ctx, "t1").should eq(7)
  end

  it "scrolls the wheel when rows exceeds the visible area" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new(
      (1..60).map { |i| "line #{i}" }.join("\n") + "\n")
    # rows: 100 in a 600px window (~28 visible rows): the widget must
    # clamp its viewport to the available height — a full 100-row rect
    # would make the whole 60-line document "fit" and kill scrolling.
    3.times { |i| editor_frame(ctx, b, rows: 100, time: 0.016 * (i + 1)) }
    pos = Egui::Pos2.new(400.0, 300.0)
    editor_frame(ctx, b, rows: 100,
      events: [Egui::Event.pointer_moved(pos)] of Egui::Event, time: 0.064)
    editor_frame(ctx, b, rows: 100,
      events: [Egui::Event.scroll(Egui::Vec2.new(0.0, 3.0))] of Egui::Event,
      time: 0.08)
    sid = Kodkod::CodeEditor.widget_id("t1")
      .child(Kodkod::CodeEditor::SCROLL_SALT)
    off = ctx.memory.data.get_vec2(sid, Egui::Vec2.zero).y
    off.should be > 0.0
    # The published viewport is the VISIBLE height, not rows * line_h.
    view_h = ctx.memory.data.get_f64(
      Kodkod::CodeEditor.widget_id("t1")
        .child(Kodkod::CodeEditor::VIEW_H_SALT), Float64::MAX)
    view_h.should be < 60 * 20.8 # whole-document viewport would break scrolling
  end

  it "scroll_to_line keeps the target visible with live metrics" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new(
      (1..60).map { |i| "line #{i}" }.join("\n") + "\n")
    2.times { |i| editor_frame(ctx, b, rows: 100, time: 0.016 * (i + 1)) }
    # Between frames (the VIM ':' command path): the metrics the widget
    # published last frame must survive end-frame pruning.
    Kodkod::CodeEditor.scroll_to_line(ctx, "t1", 55)
    wid = Kodkod::CodeEditor.widget_id("t1")
    line_h = ctx.memory.data.get_f64(wid.child(Kodkod::CodeEditor::LINE_H_SALT), 20.0)
    view_h = ctx.memory.data.get_f64(wid.child(Kodkod::CodeEditor::VIEW_H_SALT), 400.0)
    off = ctx.memory.data.get_vec2(
      wid.child(Kodkod::CodeEditor::SCROLL_SALT), Egui::Vec2.zero).y
    y = 55 * line_h
    off.should be <= y
    y + line_h.should be <= off + view_h
  end

  it "keeps a big buffer cheap per frame (virtualization)" do
    ctx = Egui::Context.new
    line = "the quick brown fox jumps over the lazy dog\n"
    b = Kodkod::EditorBuffer.new(line * 15_000) # ~630 KiB
    t0 = Time.monotonic
    5.times do |i|
      editor_frame(ctx, b, time: 0.016 * (i + 1))
    end
    elapsed = Time.monotonic - t0
    # Five frames over a multi-hundred-KB buffer: the visible window
    # is the only thing laid out (generous bound for a debug build).
    elapsed.total_seconds.should be < 1.5
    b.rope.line_count.should eq(15_001) # trailing phantom line
  end

  it "draws a vim-style block caret that inverts the char under it" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "t1")
    editor_frame(ctx, b)
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "t1", 0) # caret over 'h'
    editor_frame(ctx, b, time: 0.032)

    # No thin vertical caret line (the gutter separator stays: it is
    # separator-colored, spans the editor, not text-colored).
    text_c = ctx.style.visuals.text_color
    ctx.painter.commands.select(Egui::LineCmd)
      .select { |l| l.p1.x == l.p2.x && l.color == text_c }.should be_empty
    caret = ctx.painter.commands.select(Egui::RectCmd)
      .select { |c| c.fill && !c.stroke_color &&
                     c.rect.width > 3.0 && c.rect.width < 60.0 &&
                     c.rect.height > 8.0 }
    caret.should_not be_empty
    # ...and 'h' is re-painted over the fill in the editor background
    # (the galley run draws the whole row; the standalone "h" IS the
    # inverted repaint).
    bg = ctx.style.visuals.window_fill
    ctx.painter.commands.select(Egui::TextCmd)
      .count { |t| t.text == "h" && t.color == bg }.should eq(1)

    # Bar style (VIM insert): a 2px bar at the cell edge, no repaint.
    editor_frame(ctx, b, cursor_style: :bar, time: 0.048)
    bars = ctx.painter.commands.select(Egui::RectCmd)
      .select { |c| c.fill && !c.stroke_color &&
                     (c.rect.width - 2.0).abs < 0.01 && c.rect.height > 8.0 }
    bars.should_not be_empty
    ctx.painter.commands.select(Egui::TextCmd)
      .count { |t| t.text == "h" && t.color == bg }.should eq(0)
  end
end
