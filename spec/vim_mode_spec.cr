require "spec"
require "../src/vim_mode"

VSCREEN2 = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# A frame that mirrors the app wiring: the editor renders with
# keyboard: false while VIM is modal, then the VIM layer handles the
# same frame's input through the widget's public API — INSIDE the
# panel block, after the editor (central_panel blocks are deferred to
# end_frame; calling handle outside would invert the order and the
# widget would see the mode this frame's keys already switched to).
def vim_frame(ctx : Egui::Context, vim : Kodkod::VimMode,
              buffer : Kodkod::EditorBuffer, fid : String,
              events : Array(Egui::Event) = [] of Egui::Event,
              time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(VSCREEN2, events, time))
  ctx.central_panel do |ui|
    ui.code_editor(buffer, focus_id: fid,
      keyboard: vim.widget_keyboard,
      escape_clears_focus: false, rows: 20)
    vim.handle(ctx, buffer, fid)
  end
  ctx.end_frame
end

def type(s : String) : Array(Egui::Event)
  s.chars.map { |c| Egui::Event.text_input(c.to_s) }
end

describe Kodkod::VimMode do
  it "starts in normal mode and enters insert on i" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("abc")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim.mode.normal?.should be_true

    vim_frame(ctx, vim, b, "v1", events: type("i"), time: 0.048)
    vim.mode.insert?.should be_true
    # Insert mode hands the keyboard to the widget.
    vim.widget_keyboard.should be_true
  end

  it "types in insert mode and Esc returns to normal, stepping left" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type("i"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("hi"), time: 0.064)
    b.text.should eq("hi")
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::Escape)],
      time: 0.08)
    vim.mode.normal?.should be_true
    Kodkod::CodeEditor.cursor_offset(ctx, "v1").should eq(1) # on "i"
  end

  it "dd deletes a line and u undoes it" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\nthree\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 1, 0) # line "two"
    vim_frame(ctx, vim, b, "v1", events: type("dd"), time: 0.048)
    b.text.should eq("one\nthree\n")
    vim_frame(ctx, vim, b, "v1", events: type("u"), time: 0.064)
    b.text.should eq("one\ntwo\nthree\n")
  end

  it "dd deletes the empty phantom last line (eats the join newline)" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\nthree\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 3, 0) # phantom line 4
    vim_frame(ctx, vim, b, "v1", events: type("dd"), time: 0.048)
    b.text.should eq("one\ntwo\nthree")
    Kodkod::CodeEditor.cursor(ctx, b, "v1").should eq({2, 0})
  end

  it "dd deletes a non-empty last line without trailing newline" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\nthree")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 2, 0) # "three", last line
    vim_frame(ctx, vim, b, "v1", events: type("dd"), time: 0.048)
    b.text.should eq("one\ntwo")
    vim_frame(ctx, vim, b, "v1", events: type("u"), time: 0.064)
    b.text.should eq("one\ntwo\nthree")
  end

  it "dd on the only line empties the buffer" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("abc")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type("dd"), time: 0.048)
    b.text.should eq("")
  end

  it "yy on the last line yanks linewise (p pastes a line below)" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 1, 0) # "two", last line
    vim_frame(ctx, vim, b, "v1", events: type("yy"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("p"), time: 0.064)
    b.text.should eq("one\ntwo\ntwo")
  end

  it "3j moves down three lines keeping the column" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("aaaa\nbbbb\ncccc\ndddd\neeee\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 1)
    vim_frame(ctx, vim, b, "v1", events: type("3j"), time: 0.048)
    Kodkod::CodeEditor.cursor(ctx, b, "v1").should eq({3, 1})
  end

  it "x deletes a char at the caret" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 1)
    vim_frame(ctx, vim, b, "v1", events: type("x"), time: 0.048)
    b.text.should eq("hllo")
  end

  it "cw changes a word (delete + insert mode)" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("foo bar")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type("cw"), time: 0.048)
    b.text.should eq(" bar")
    vim.mode.insert?.should be_true
    vim_frame(ctx, vim, b, "v1", events: type("qux"), time: 0.064)
    b.text.should eq("qux bar")
  end

  it "yy copies a line and p pastes it below" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("yy"), time: 0.048)
    b.text.should eq("one\ntwo\n") # yank does not change the buffer
    vim_frame(ctx, vim, b, "v1", events: type("p"), time: 0.064)
    b.text.should eq("one\none\ntwo\n")
  end

  it "A appends at line end and types there" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("ab\ncd")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("A"), time: 0.048)
    vim.mode.insert?.should be_true
    vim_frame(ctx, vim, b, "v1", events: type("!"), time: 0.064)
    b.text.should eq("ab!\ncd")
  end

  it ":123 jumps to a line through the command line" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new((1..10).join("\n"))
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type(":"), time: 0.048)
    vim.mode.command?.should be_true
    vim_frame(ctx, vim, b, "v1", events: type("3"), time: 0.064)
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::Enter)],
      time: 0.08)
    vim.mode.normal?.should be_true
    Kodkod::CodeEditor.cursor(ctx, b, "v1").should eq({2, 0})
  end

  it ":w runs the registered write command" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("x")
    saved = 0
    vim.commands.register("w") do |c|
      saved += 1
      Kodkod::VimCommand::Result.ok
    end
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type(":w"), time: 0.048)
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::Enter)],
      time: 0.064)
    saved.should eq(1)
    vim.mode.normal?.should be_true
  end

  it ":zzz Enter reports E492 and returns to normal" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("x")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type(":zzz"), time: 0.048)
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::Enter)],
      time: 0.064)
    vim.mode.normal?.should be_true
    msg = vim.commands.last_message.not_nil!
    msg.kind.error?.should be_true
    msg.text.should contain("E492")
  end

  it "Backspace on an empty command line returns to normal" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("x")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type(":"), time: 0.048)
    vim.mode.command?.should be_true
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::Backspace)],
      time: 0.064)
    vim.mode.normal?.should be_true
    vim.command.should be_empty
  end

  it "visual mode selects and d deletes" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello world")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.048)
    vim.mode.visual?.should be_true
    vim_frame(ctx, vim, b, "v1", events: type("lll"), time: 0.064)
    vim_frame(ctx, vim, b, "v1", events: type("d"), time: 0.08)
    vim.mode.normal?.should be_true
    b.text.should eq("o world")
  end

  it "v without motion: d eats the char under the caret" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 1)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("d"), time: 0.064)
    vim.mode.normal?.should be_true
    b.text.should eq("hllo")
  end

  it "v again leaves visual mode" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.064)
    vim.mode.normal?.should be_true
  end

  it "c changes the visual selection" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("llc"), time: 0.064)
    vim.mode.insert?.should be_true
    b.text.should eq("lo")
    vim_frame(ctx, vim, b, "v1", events: type("X"), time: 0.08)
    b.text.should eq("Xlo")
  end

  it "o swaps the visual ends" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello world")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 2)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("ll"), time: 0.064)
    vim_frame(ctx, vim, b, "v1", events: type("o"), time: 0.08)
    vim_frame(ctx, vim, b, "v1", events: type("l"), time: 0.096)
    vim_frame(ctx, vim, b, "v1", events: type("d"), time: 0.112)
    vim.mode.normal?.should be_true
    b.text.should eq("hel world") # deleted the "lo" at offsets 3..4
  end

  it "V selects a line and d deletes it whole" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\nthree\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 1, 1) # middle of "two"
    vim_frame(ctx, vim, b, "v1", events: type("V"), time: 0.048)
    vim.mode.visual?.should be_true
    vim.visual_line?.should be_true
    vim.status_label.should eq("-- VISUAL LINE --")
    vim_frame(ctx, vim, b, "v1", events: type("d"), time: 0.064)
    vim.mode.normal?.should be_true
    b.text.should eq("one\nthree\n")
  end

  it "V j extends linewise and d deletes both lines" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\nthree\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("V"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("jd"), time: 0.064)
    vim.mode.normal?.should be_true
    b.text.should eq("three\n")
  end

  it "V k extends upwards linewise" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\nthree\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 2, 2) # middle of "three"
    vim_frame(ctx, vim, b, "v1", events: type("V"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("kkd"), time: 0.064)
    vim.mode.normal?.should be_true
    b.text.should eq("")
  end

  it "V c deletes the line and enters insert" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("one\ntwo\n")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("V"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("c"), time: 0.064)
    vim.mode.insert?.should be_true
    b.text.should eq("two\n")
    vim_frame(ctx, vim, b, "v1", events: type("X"), time: 0.08)
    b.text.should eq("Xtwo\n")
  end

  it "V then v switches to charwise keeping visual mode" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    vim_frame(ctx, vim, b, "v1", events: type("V"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.064)
    vim.mode.visual?.should be_true
    vim.visual_line?.should be_false
    vim.status_label.should eq("-- VISUAL --")
  end

  it "gg jumps to the top" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("a\nb\nc")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 2, 0)
    vim_frame(ctx, vim, b, "v1", events: type("gg"), time: 0.048)
    Kodkod::CodeEditor.cursor(ctx, b, "v1").should eq({0, 0})
  end

  it "f finds a char on the line" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("aXbXc")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("f"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("X"), time: 0.064)
    Kodkod::CodeEditor.cursor(ctx, b, "v1").should eq({0, 1})
  end

  it "Ctrl+C copies a mouse-made selection in normal mode" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello world")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    # What a mouse drag leaves behind: a caret/anchor pair.
    Kodkod::CodeEditor.set_selection(ctx, "v1", 0, 5)
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::C,
        Egui::Modifiers.new(ctrl: true))],
      time: 0.048)
    Egui::SystemPorts::Clipboard.text.should eq("hello")
    b.text.should eq("hello world") # copy only
    vim.mode.normal?.should be_true
  end

  it "Backspace deletes a mouse-made selection in normal mode" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello world")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_selection(ctx, "v1", 0, 5)
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::Backspace)],
      time: 0.048)
    b.text.should eq(" world")
    Kodkod::CodeEditor.cursor_offset(ctx, "v1").should eq(0)
  end

  it "Ctrl+X cuts a mouse-made selection in normal mode" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello world")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_selection(ctx, "v1", 0, 5)
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::X,
        Egui::Modifiers.new(ctrl: true))],
      time: 0.048)
    Egui::SystemPorts::Clipboard.text.should eq("hello")
    b.text.should eq(" world")
  end

  it "Ctrl+C yanks and leaves visual mode" do
    ctx = Egui::Context.new
    vim = Kodkod::VimMode.new
    b = Kodkod::EditorBuffer.new("hello")
    Kodkod::CodeEditor.request_focus(ctx, "v1")
    vim_frame(ctx, vim, b, "v1")
    vim_frame(ctx, vim, b, "v1", time: 0.032)
    Kodkod::CodeEditor.set_cursor(ctx, b, "v1", 0, 0)
    vim_frame(ctx, vim, b, "v1", events: type("v"), time: 0.048)
    vim_frame(ctx, vim, b, "v1", events: type("l"), time: 0.056)
    vim.mode.visual?.should be_true
    vim_frame(ctx, vim, b, "v1",
      events: [Egui::Event.key_pressed(Egui::KeyCode::C,
        Egui::Modifiers.new(ctrl: true))],
      time: 0.064)
    Egui::SystemPorts::Clipboard.text.should eq("he")
    vim.mode.normal?.should be_true
  end
end
