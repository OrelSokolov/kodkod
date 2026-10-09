require "spec"
require "../src/vim_command"

VSCREEN3 = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# The builtins (:{n}, :noh) drive the editor widget's memory cells, so
# run() is exercised INSIDE a frame with the widget rendered — the same
# wiring the app uses.
def cmd_frame(ctx : Egui::Context, runner : Kodkod::VimCommand::Runner,
              buffer : Kodkod::EditorBuffer, fid : String,
              line : String, time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(VSCREEN3,
    [] of Egui::Event, time))
  ctx.central_panel do |ui|
    ui.code_editor(buffer, focus_id: fid, keyboard: false, rows: 20)
    runner.run(ctx, buffer, fid, line)
  end
  ctx.end_frame
end

def setup_runner(fid : String)
  ctx = Egui::Context.new
  runner = Kodkod::VimCommand::Runner.new
  buffer = Kodkod::EditorBuffer.new("one\ntwo\nthree\n")
  Kodkod::CodeEditor.request_focus(ctx, fid)
  {ctx, runner, buffer}
end

describe Kodkod::VimCommand::Runner do
  it "runs an exact command name" do
    ctx, runner, b = setup_runner("c1")
    called = false
    runner.register("tabclose") { |c| called = true; Kodkod::VimCommand::Result.ok }
    cmd_frame(ctx, runner, b, "c1", "tabclose")
    called.should be_true
  end

  it "resolves a unique prefix to the full name" do
    ctx, runner, b = setup_runner("c2")
    seen = ""
    runner.register("tabclose") do |c|
      seen = "close"; Kodkod::VimCommand::Result.ok
    end
    runner.register("wq") do |c|
      seen = "wq"; Kodkod::VimCommand::Result.ok
    end
    cmd_frame(ctx, runner, b, "c2", "tabcl")
    seen.should eq("close")
  end

  it "reports ambiguous prefixes as E464" do
    ctx, runner, b = setup_runner("c3")
    runner.register("tabclose") { |c| Kodkod::VimCommand::Result.ok }
    runner.register("tabnext") { |c| Kodkod::VimCommand::Result.ok }
    cmd_frame(ctx, runner, b, "c3", "tab")
    msg = runner.last_message.not_nil!
    msg.kind.error?.should be_true
    msg.text.should contain("E464")
  end

  it "reports unknown commands as E492" do
    ctx, runner, b = setup_runner("c4")
    cmd_frame(ctx, runner, b, "c4", "zzz")
    msg = runner.last_message.not_nil!
    msg.kind.error?.should be_true
    msg.text.should contain("E492: Not an editor command: zzz")
  end

  it "parses a trailing bang into force and the rest into args" do
    ctx, runner, b = setup_runner("c5")
    force = true
    args = ""
    runner.register("quit") do |c|
      force = c.force?
      args = c.args
      Kodkod::VimCommand::Result.ok
    end
    cmd_frame(ctx, runner, b, "c5", "q! now")
    force.should be_true
    args.should eq("now")
  end

  it "defaults to no force and empty args" do
    ctx, runner, b = setup_runner("c6")
    force = false
    runner.register("write") do |c|
      force = c.force?
      Kodkod::VimCommand::Result.ok
    end
    cmd_frame(ctx, runner, b, "c6", "w")
    force.should be_false
  end

  it ":{n} jumps to a line without a message" do
    ctx, runner, b = setup_runner("c7")
    cmd_frame(ctx, runner, b, "c7", "2")
    Kodkod::CodeEditor.cursor(ctx, b, "c7").should eq({1, 0})
    runner.last_message.should be_nil
  end

  it ":noh drops the selection" do
    ctx, runner, b = setup_runner("c8")
    cmd_frame(ctx, runner, b, "c8", "1") # position first
    Kodkod::CodeEditor.set_selection(ctx, "c8", 0, 3)
    cmd_frame(ctx, runner, b, "c8", "nohlsearch", time: 0.032)
    Kodkod::CodeEditor.selection(ctx, "c8").should be_nil
  end

  it "keeps only the last message and clears it on an empty line" do
    ctx, runner, b = setup_runner("c9")
    runner.register("write") { |c| Kodkod::VimCommand::Result.ok("Saved.") }
    cmd_frame(ctx, runner, b, "c9", "w")
    runner.last_message.not_nil!.text.should eq("Saved.")
    cmd_frame(ctx, runner, b, "c9", "", time: 0.032)
    runner.last_message.should be_nil
  end

  it "lets the app override a builtin registration" do
    ctx, runner, b = setup_runner("c10")
    runner.register("nohlsearch") { |c| Kodkod::VimCommand::Result.warn("mine") }
    cmd_frame(ctx, runner, b, "c10", "noh")
    runner.last_message.not_nil!.text.should eq("mine")
  end

  # The app registers quit/qall/write/wq/wqall plus the exact aliases
  # "q"/"w" — without them, :q and :w are ambiguous prefixes (E464).
  it "resolves exact short aliases past ambiguous prefixes (:q, :w)" do
    ctx, runner, b = setup_runner("c11")
    seen = ""
    runner.register("quit") { |c| seen = "quit"; Kodkod::VimCommand::Result.ok }
    runner.register("qall") { |c| seen = "qall"; Kodkod::VimCommand::Result.ok }
    runner.register("q") { |c| seen = "q"; Kodkod::VimCommand::Result.ok }
    runner.register("write") { |c| seen = "write"; Kodkod::VimCommand::Result.ok }
    runner.register("wq") { |c| seen = "wq"; Kodkod::VimCommand::Result.ok }
    runner.register("wqall") { |c| seen = "wqall"; Kodkod::VimCommand::Result.ok }
    runner.register("w") { |c| seen = "w"; Kodkod::VimCommand::Result.ok }

    cmd_frame(ctx, runner, b, "c11", "q")
    seen.should eq("q")
    runner.last_message.should be_nil

    cmd_frame(ctx, runner, b, "c11", "w", time: 0.032)
    seen.should eq("w")
    runner.last_message.should be_nil

    # Longer prefixes stay prefix-resolved: :qa → qall, :wqa → wqall.
    cmd_frame(ctx, runner, b, "c11", "qa", time: 0.048)
    seen.should eq("qall")
    cmd_frame(ctx, runner, b, "c11", "wqa", time: 0.064)
    seen.should eq("wqall")
  end
end
