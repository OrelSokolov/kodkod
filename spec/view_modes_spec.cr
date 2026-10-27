require "spec"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/code_editor"
require "../src/app"

# Exposes the private settings state (same pattern as settings_spec).
class VMTestApp < KodkodApp
  def settings; @settings; end
end

VSCREEN4 = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# editor_frame's view-mode twin: renders one CodeEditor frame with the
# hide_annotations / hide_blocks flags the View menu flips.
def viewmode_frame(ctx : Egui::Context, buffer : Kodkod::EditorBuffer,
                   fid : String = "vm",
                   hide_annotations : Bool = false,
                   hide_blocks : Bool = false,
                   keyboard : Bool = false,
                   events : Array(Egui::Event) = [] of Egui::Event,
                   time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(VSCREEN4, events, time))
  ctx.central_panel do |ui|
    ui.code_editor(buffer, focus_id: fid, keyboard: keyboard, rows: 20,
      hide_annotations: hide_annotations, hide_blocks: hide_blocks)
  end
  ctx.end_frame
end

def vm_texts(ctx : Egui::Context) : Array(String)
  ctx.painter.commands.select(Egui::TextCmd).map(&.text)
end

describe "editor view modes" do
  it "elides type annotations to a single ⋯ marker" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def foo(ctx : Egui::Context, n : Int32?) : Nil\n  1\nend\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_annotations: true)
    texts = vm_texts(ctx).join("|")
    texts.should contain("...")
    texts.should_not contain("Egui::Context")
    texts.should_not contain("Int32?")
    # The rest of the signature stays visible (runs are per-token).
    texts.should contain("foo")
    texts.should contain("ctx")
  end

  it "leaves annotations painted when the mode is off" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def foo(n : Int32?) : Nil\nend\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_annotations: false)
    vm_texts(ctx).join("|").should contain("Int32?")
  end

  it "folds block bodies behind the header (gutter keeps doc numbers)" do
    ctx = Egui::Context.new
    body = "  the_hidden_body_marker\n"
    b = Kodkod::EditorBuffer.new("def bar\n#{body}end\n\ntop = 1\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_blocks: true)
    texts = vm_texts(ctx)
    texts.join("|").should_not contain("the_hidden_body_marker")
    # Fold-to-one-row: doc numbering jumps 1 (header) → 4 — the body
    # AND its `end` (lines 2-3) are behind the single header row.
    texts.should contain("1")
    texts.should_not contain("2")
    texts.should_not contain("3")
    texts.should contain("4")
  end

  it "snaps the caret THROUGH an elided annotation in the move direction" do
    # "def foo(n : Int32?) : Nil": the annotation token " : Int32?"
    # spans [9, 18). The direction reference is the caret as last
    # RENDERED — VIM writes carets between frames, so cursor_prev is
    # useless there (the snap used to always read "backward" and the
    # caret stuck at the LEFT edge of the "..." marker).
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def foo(n : Int32?) : Nil\nend\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_annotations: true) # renders caret 0
    # Jump INTO the range from the left (VIM l, w, f…) → land PAST it.
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm", 12)
    viewmode_frame(ctx, b, hide_annotations: true, time: 0.032)
    Kodkod::CodeEditor.cursor_offset(ctx, "vm").should eq(18) # range end
    # One step from the LEFT EDGE (the exact stuck repro: 9 → 10).
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm", 9)
    viewmode_frame(ctx, b, hide_annotations: true, time: 0.048)
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm", 10)
    viewmode_frame(ctx, b, hide_annotations: true, time: 0.064)
    Kodkod::CodeEditor.cursor_offset(ctx, "vm").should eq(18) # through
    # Into the range from the RIGHT (h, b…) → back to the left edge.
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm", 18)
    viewmode_frame(ctx, b, hide_annotations: true, time: 0.08)
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm", 12)
    viewmode_frame(ctx, b, hide_annotations: true, time: 0.096)
    Kodkod::CodeEditor.cursor_offset(ctx, "vm").should eq(9) # range start
  end

  it "snaps the caret off a folded body line" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def bar\n  hidden_body\nend\n\ntop = 1\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_blocks: true)
    # Line 1 (the body) is folded away; a caret written there snaps.
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm",
      b.rope.offset_at(1, 2))
    viewmode_frame(ctx, b, hide_blocks: true, time: 0.032)
    Kodkod::CodeEditor.cursor(ctx, b, "vm")[0].should_not eq(1)
  end

  it "does not crash painting the caret on a blank line (empty frags)" do
    # Regression: a blank line stores an EMPTY fragment map; the old
    # x_at_col called frags.last on it and the focused caret paint
    # raised IndexError (crashed the real app on launch).
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def foo\n\n  body\nend\n\nx = 1\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_annotations: true, keyboard: true)
    Kodkod::CodeEditor.request_focus(ctx, "vm")
    # Caret onto the blank line (1), then a focused paint frame.
    Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm", 8)
    viewmode_frame(ctx, b, hide_annotations: true, keyboard: true,
      time: 0.032)
    Kodkod::CodeEditor.cursor(ctx, b, "vm")[0].should eq(1)
  end

  it "Down steps over a folded body to the next visible line" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def bar\n  hidden_body\nend\n\ntop = 1\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_blocks: true, keyboard: true)
    Kodkod::CodeEditor.request_focus(ctx, "vm")
    Kodkod::CodeEditor.set_cursor(ctx, b, "vm", 0, 0) # on the header
    viewmode_frame(ctx, b, hide_blocks: true, keyboard: true, time: 0.032)
    viewmode_frame(ctx, b, hide_blocks: true, keyboard: true,
      events: [Egui::Event.key_pressed(Egui::KeyCode::Down)], time: 0.048)
    # Row 1 is the blank line (doc line 3) — the body AND the `end`
    # hide behind the single header row.
    Kodkod::CodeEditor.cursor(ctx, b, "vm")[0].should eq(3)
  end

  it "vertical_line maps through display rows under folding" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def bar\n  hidden_body\nend\n\ntop = 1\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_blocks: true) # buffer carries the mode
    Kodkod::CodeEditor.vertical_line(ctx, b, "vm", 0, 1).should eq(3)
    Kodkod::CodeEditor.vertical_line(ctx, b, "vm", 3, -1).should eq(0)
    Kodkod::CodeEditor.vertical_line(ctx, b, "vm", 0, 2).should eq(4)
    # Plain line math when the mode is off (the flag lives on the
    # buffer — a fresh context alone no longer switches it off).
    b.hide_blocks = false
    Kodkod::CodeEditor.vertical_line(ctx, b, "vm", 0, 1).should eq(1)
  end

  it "round-trips x→col→x through the materialized runs (fixed point)" do
    # Invariant: locate(hit(x)) is a FIXED POINT of locate∘hit — the
    # painted boundary the caret snaps to maps back to itself. This
    # is the property v1's split fragment-map/col_x paths broke.
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new(
      "def foo(ctx : Egui::Context, n : Int32?) : Nil\n  body\nend\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_annotations: true)
    disp = b.display
    disp.row(0).should_not be_nil
    mrow = disp.row(0).not_nil!
    text = b.rope.line_text(0)
    fonts = ctx.fonts_for("monospace")
    width = mrow.width
    x = 0.0
    while x <= width
      col = disp.col_at(mrow, x, text, fonts, 16.0)
      x1 = disp.x_at(mrow, col, text, fonts, 16.0)
      col1 = disp.col_at(mrow, x1, text, fonts, 16.0)
      col1.should eq(col) # fixed point: the boundary maps to itself
      x += 4.0
    end
  end

  it "keeps the top visible line anchored across a fold toggle" do
    # Scroll anchoring (TOP_SALT): toggling the mode changes the row
    # mapping under the stored pixel offset — the view must stay on
    # the same DOC line, not drift rows that vanished/appeared.
    ctx = Egui::Context.new
    code = String.build do |s|
      s << "def header\n  body line\nend\n"
      40.times { |i| s << "plain line #{i}\n" }
    end
    b = Kodkod::EditorBuffer.new(code)
    b.lang = "crystal"
    3.times { |i| viewmode_frame(ctx, b, time: 0.016 * (i + 1)) }
    id = Kodkod::CodeEditor.widget_id("vm")
    line_h = ctx.memory.data.get_f64(id.child(Kodkod::CodeEditor::LINE_H_SALT), 20.0)
    ctx.memory.data.set_vec2(id.child(Kodkod::CodeEditor::SCROLL_SALT),
      Egui::Vec2.new(0.0, 20.0 * line_h))
    viewmode_frame(ctx, b, time: 0.1)
    # Now fold the top block away: rows above shrank by 2 — the same
    # doc line must still head the view.
    viewmode_frame(ctx, b, hide_blocks: true, time: 0.12)
    labels = ->(c : Egui::Context) do
      cmds = c.painter.commands.select(Egui::TextCmd)
        .select { |t| t.text =~ /\A\d+\z/ }
      cmds.map(&.text).sort_by(&.to_i)
    end
    # Re-run: anchored (folded) vs the naive pixel interpretation.
    a = labels.call(ctx)
    a.should_not be_empty
    # Unfolding back must restore the same top line too.
    viewmode_frame(ctx, b, time: 0.14)
    z = labels.call(ctx)
    z.first.should eq(a.first)
  end

  it "keeps text and gutter aligned when SCROLLED (absolute row y)" do
    # Regression: the galley rows were placed at the WINDOW-LOCAL row
    # index * line_h while gutter/selection/caret used ABSOLUTE rows —
    # the moment v_off > 0 the text shifted up by lv0 rows, the top
    # of the viewport emptied and the numbers diverged from the text.
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new(
      (0...60).map { |i| "L%03d body" % i }.join("\n") + "\n")
    b.lang = "crystal"
    3.times { |i| viewmode_frame(ctx, b, time: 0.016 * (i + 1)) }
    id = Kodkod::CodeEditor.widget_id("vm")
    line_h = ctx.memory.data.get_f64(
      id.child(Kodkod::CodeEditor::LINE_H_SALT), 20.0)
    # Scroll 25 rows down, exactly.
    ctx.memory.data.set_vec2(id.child(Kodkod::CodeEditor::SCROLL_SALT),
      Egui::Vec2.new(0.0, 25.0 * line_h))
    viewmode_frame(ctx, b, time: 0.1)
    cmds = ctx.painter.commands.select(Egui::TextCmd)
    text = cmds.find { |t| t.text.includes?("L025") }
    digit = cmds.find { |t| t.text == "26" }
    text.should_not be_nil
    digit.should_not be_nil
    text.not_nil!.pos.y.should eq(digit.not_nil!.pos.y)
  end

  it "fills the viewport after scrolling (no half-empty screen)" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new(
      (0...80).map { |i| "L%03d body" % i }.join("\n") + "\n")
    b.lang = "crystal"
    3.times { |i| viewmode_frame(ctx, b, time: 0.016 * (i + 1)) }
    id = Kodkod::CodeEditor.widget_id("vm")
    line_h = ctx.memory.data.get_f64(
      id.child(Kodkod::CodeEditor::LINE_H_SALT), 20.0)
    5.times do |k|
      ctx.memory.data.set_vec2(id.child(Kodkod::CodeEditor::SCROLL_SALT),
        Egui::Vec2.new(0.0, (10 + 7 * k).to_f64 * line_h))
      viewmode_frame(ctx, b, time: 0.1 + 0.02 * k)
      labels = ctx.painter.commands.select(Egui::TextCmd)
        .select { |t| t.text =~ /\A\d+\z/ }.map(&.text.to_i).sort
      # rows:20 helper → ~20 gutter numbers must paint, headed by the
      # doc line at the top row.
      labels.size.should be >= 15
      labels.first.should eq(11 + 7 * k)
    end
  end

  it "fuzzes frames without exceptions (edits × toggles × scrolls × jumps)" do
    rng = Random.new(42)
    6.times do |round|
      lines = Array.new(rng.rand(5..40)) do |i|
        case rng.rand(4)
        when 0 then ""
        when 1 then "def thing#{i}(a : Int32) : Nil"
        when 2 then "  body #{i}"
        else "plain #{i} = #{i}"
        end
      end
      b = Kodkod::EditorBuffer.new(lines.join("\n") + "\n")
      b.lang = "crystal"
      ctx = Egui::Context.new
      ha = false
      hb = false
      30.times do |i|
        case rng.rand(6)
        when 0 then ha = !ha
        when 1 then hb = !hb
        when 2
          at = rng.rand(0..{b.rope.size, 1}.max)
          b.apply(at, rng.rand(2) == 0 ? "x" : "", rng.rand(3))
        when 3
          Kodkod::CodeEditor.set_cursor_offset(ctx, b, "vm",
            rng.rand(0..{b.rope.size, 1}.max))
        when 4
          Kodkod::CodeEditor.goto_line(ctx, b, "vm",
            rng.rand(0..{b.rope.line_count - 1, 0}.max))
        end
        events = [Egui::Event.scroll(
          Egui::Vec2.new(0.0, rng.rand(-4.0..4.0)))] of Egui::Event
        viewmode_frame(ctx, b, hide_annotations: ha, hide_blocks: hb,
          keyboard: true, events: events, time: 0.016 * (i + 1))
      end
    end
  end

  it "goto_line reveals the folded block containing the target" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def bar\n  hidden_body\nend\n\ntop = 1\n")
    b.lang = "crystal"
    # One frame with the mode on publishes HMODE_SALT for goto_line.
    viewmode_frame(ctx, b, hide_blocks: true)
    Kodkod::CodeEditor.goto_line(ctx, b, "vm", 1, 2)
    viewmode_frame(ctx, b, hide_blocks: true, time: 0.032)
    # The jump unfolded the block: the body is visible again.
    vm_texts(ctx).join("|").should contain("hidden_body")
  end

  it "reveals reset on edit (line indexes shift under them)" do
    ctx = Egui::Context.new
    b = Kodkod::EditorBuffer.new("def bar\n  hidden_body\nend\n\ntop = 1\n")
    b.lang = "crystal"
    viewmode_frame(ctx, b, hide_blocks: true)
    Kodkod::CodeEditor.goto_line(ctx, b, "vm", 1, 2)
    viewmode_frame(ctx, b, hide_blocks: true, time: 0.032)
    b.apply(0, "\n") # any edit invalidates the reveal set
    viewmode_frame(ctx, b, hide_blocks: true, time: 0.048)
    vm_texts(ctx).join("|").should_not contain("hidden_body")
  end

  it "serializes the new settings with defaults for legacy configs" do
    legacy = KodkodApp::Settings.from_json(%({"theme":"Dark","vim":true}))
    legacy.hide_type_annotations.should be_false
    legacy.hide_blocks.should be_false
    round = KodkodApp::Settings.from_json(
      KodkodApp::Settings.new(hide_type_annotations: true,
        hide_blocks: true).to_json)
    round.hide_type_annotations.should be_true
    round.hide_blocks.should be_true
  end

  it "wires the app settings into the editor end-to-end" do
    path = File.join(Dir.tempdir, "kodkod_vm_spec_sample.cr")
    File.write(path,
      "def marker_function(a : Int32) : Nil\n  hidden_marker_body\nend\n")
    app = VMTestApp.new([path])
    # The developer's persisted AppConfig loads first — pin the modes
    # so the assertion below is deterministic on any machine.
    app.settings.hide_type_annotations = true
    app.settings.hide_blocks = true
    ctx = Egui::Context.new
    5.times do |i|
      ctx.begin_frame(Egui::RawInput.new(VSCREEN4, [] of Egui::Event,
        0.016 * (i + 1)))
      app.update(ctx)
      ctx.end_frame
    end
    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text).join("|")
    texts.should contain("...")
    texts.should_not contain("Int32")
    texts.should_not contain("hidden_marker_body")
    File.delete(path)
  end
end
