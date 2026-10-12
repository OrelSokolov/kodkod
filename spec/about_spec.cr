require "spec"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/app"

ASCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(1200.0, 800.0))

# Exposes the private state so the spec can pin the locale — the app
# loads the PERSISTED settings, whose language varies by machine.
class AboutTestApp < KodkodApp
  def i18n; @i18n; end
  def about_open?; @about_open; end
end

def about_frame(app : AboutTestApp, ctx : Egui::Context,
                events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016) : Array(Egui::PaintCmd)
  ctx.begin_frame(Egui::RawInput.new(ASCREEN, events, time))
  app.update(ctx)
  ctx.end_frame
end

# Click whatever TextCmd matches `needle` (layout positions are the
# page's business, not the spec's — same approach as settings_spec).
def about_click(cmds, app, ctx, needle, time) : Bool
  text = cmds.find { |c| c.is_a?(Egui::TextCmd) && c.text.includes?(needle) }
  return false unless text
  pos = text.not_nil!.as(Egui::TextCmd).pos
  about_frame(app, ctx, events: [Egui::Event.pointer_moved(pos),
    Egui::Event.pointer_pressed(pos), Egui::Event.pointer_released(pos)],
    time: time)
  true
end

describe "about modal" do
  it "opens from the Help menu and closes on its button" do
    app = AboutTestApp.new([] of String)
    app.i18n.locale = "en"
    ctx = Egui::Context.new
    3.times { |i| about_frame(app, ctx, time: 0.016 * (i + 1)) }

    # Help → About kodkod, then the modal renders over the editor.
    cmds = about_frame(app, ctx, time: 0.1)
    about_click(cmds, app, ctx, "Help", 0.12).should be_true
    cmds = about_frame(app, ctx, time: 0.13)
    about_click(cmds, app, ctx, "About kodkod", 0.15).should be_true
    app.about_open?.should be_true

    cmds = about_frame(app, ctx, time: 0.17)
    texts = cmds.select(Egui::TextCmd).map(&.text.as(String))
    texts.join("\n").should contain("kodkod #{Kodkod::About::VERSION}")
    texts.join("\n").should contain("A code editor on egui-cr")

    # Close: the modal page pops off the route stack.
    about_click(cmds, app, ctx, "Close", 0.19).should be_true
    about_frame(app, ctx, time: 0.21)
    app.about_open?.should be_false
  end
end
