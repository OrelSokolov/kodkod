require "spec"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/app"

# Exposes the private settings/vim/i18n state for the flicker assertions.
class SettingsTestApp < KodkodApp
  def settings; @settings; end
  def vim; @vim; end
  def i18n; @i18n; end
end

SSCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(1200.0, 800.0))

def settings_frame(app : SettingsTestApp, ctx : Egui::Context,
                   events : Array(Egui::Event) = [] of Egui::Event,
                   time : Float64 = 0.016) : Array(Egui::PaintCmd)
  ctx.begin_frame(Egui::RawInput.new(SSCREEN, events, time))
  app.update(ctx)
  ctx.end_frame
end

describe "settings page" do
  it "does not toggle settings on plain mouse-move frames" do
    # Regression: `if ui.selectable_label(...)` — any object is truthy
    # in Crystal, so the toggle blocks fired EVERY frame and the page
    # flickered while the mouse moved (frames run per input event).
    app = SettingsTestApp.new([] of String)
    ctx = Egui::Context.new
    5.times { |i| settings_frame(app, ctx, time: 0.016 * (i + 1)) }
    ctx.router.navigate("root/settings")
    settings_frame(app, ctx, time: 0.1)
    # Let the default-open expanders finish their reveal (one measuring
    # frame + the 0.2 s slide) before sweeping the pointer.
    20.times { |i| settings_frame(app, ctx, time: 0.12 + 0.016 * (i + 1)) }

    before = {app.vim.enabled?, app.settings.show_hidden,
              app.settings.show_explorer, app.settings.cursor_blinks}
    8.times do |i|
      # sweep the pointer across the toggle rows, one move/frame
      settings_frame(app, ctx,
        events: [Egui::Event.pointer_moved(
          Egui::Pos2.new(300.0, 170.0 + (i % 4) * 30.0))],
        time: 0.4 + 0.016 * (i + 1))
    end
    after = {app.vim.enabled?, app.settings.show_hidden,
             app.settings.show_explorer, app.settings.cursor_blinks}
    after.should eq(before)
  end

  it "toggles VIM mode on a real click at the label" do
    app = SettingsTestApp.new([] of String)
    # Settings come from the developer's persisted AppConfig — pin the
    # locale so the label below is found whatever the machine saved.
    app.i18n.locale = "en"
    ctx = Egui::Context.new
    3.times { |i| settings_frame(app, ctx, time: 0.016 * (i + 1)) }
    ctx.router.navigate("root/settings")
    now = 0.1
    cmds = settings_frame(app, ctx, time: now)
    # Pump the clock (monotonic — animations read it) past the expanders'
    # reveal: one measuring frame paints nothing, then a 0.2 s slide
    # during which the content clip still swallows clicks.
    25.times do
      now += 0.016
      cmds = settings_frame(app, ctx, time: now)
    end

    # Locate the label from the frame's own paint commands — the
    # layout position is the page's business, not the spec's.
    text = cmds.find do |c|
      c.is_a?(Egui::TextCmd) && c.text.includes?("VIM mode")
    end
    text.should_not be_nil
    pos = text.not_nil!.as(Egui::TextCmd).pos
    was = app.vim.enabled?

    click = [Egui::Event.pointer_moved(pos),
             Egui::Event.pointer_pressed(pos),
             Egui::Event.pointer_released(pos)]
    now += 0.016
    settings_frame(app, ctx, events: click, time: now)
    app.vim.enabled?.should eq(!was)

    # Back to the saved state (the click persisted the flip).
    now += 0.016
    settings_frame(app, ctx, events: click, time: now)
    app.vim.enabled?.should eq(was)
  end
end
