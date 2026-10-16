# Tab context menu specs (batch close): "Close Others" / "Close Tabs to
# the Right" / "Close All Tabs" from the right-click tab menu must
# actually remove the tabs. Headless: WindowFrame.show is exactly what
# the sokol backend calls before app frames (see title_bar_tabs_spec).

require "spec"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/app"

TMENU_SCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(1200.0, 800.0))

class TabMenuTestApp < KodkodApp
  def i18n; @i18n; end
  getter docs
end

def tmenu_frame(app : TabMenuTestApp, ctx : Egui::Context,
                events : Array(Egui::Event) = [] of Egui::Event,
                time : Float64 = 0.016) : Array(Egui::PaintCmd)
  ctx.begin_frame(Egui::RawInput.new(TMENU_SCREEN, events, time))
  Egui::WindowFrame.show(ctx, "kodkod", Egui::WindowFrame::Style::Windows)
  app.update(ctx)
  ctx.end_frame
end

def tmenu_click_text(cmds, app, ctx, needle, time) : Bool
  text = cmds.find { |c| c.is_a?(Egui::TextCmd) && c.text.includes?(needle) }
  return false unless text
  pos = text.not_nil!.as(Egui::TextCmd).pos
  tmenu_frame(app, ctx, events: [Egui::Event.pointer_moved(pos),
    Egui::Event.pointer_pressed(pos), Egui::Event.pointer_released(pos)],
    time: time)
  true
end

# Tab i's card center (the widget's own measure formula).
def tmenu_tab_center(ctx : Egui::Context, titles : Array(String),
                     i : Int32) : Egui::Pos2
  y = Egui::TitleBarTabs::TAB_TOP_GAP +
      (Egui::TitleBarTabs::CAPTION_H - Egui::TitleBarTabs::TAB_TOP_GAP) / 2.0
  x = Egui::TitleBarTabs::FIRST_INSET
  titles.each_with_index do |t, j|
    w = {ctx.fonts.measure(t, Egui::TitleBarTabs::FONT).x +
         2 * Egui::TitleBarTabs::PAD_X +
         Egui::TitleBarTabs::ICON + Egui::TitleBarTabs::ICON_GAP,
         Egui::TitleBarTabs::MIN_W}.max
    x += w
    return Egui::Pos2.new(x - w / 2.0, y) if j == i
  end
  raise "no tab #{i}"
end

describe "tab context menu" do
  after_each do
    Egui::WindowFrame.caption!
    Egui::WindowFrame.icon = nil
  end

  it "close others / close right / close all remove the tabs" do
    Dir.mkdir_p("/tmp/kodkod_tab_menu_spec")
    files = ["a", "b", "c", "d"].map do |n|
      path = "/tmp/kodkod_tab_menu_spec/#{n}.txt"
      File.write(path, "#{n} content\n")
      path
    end

    # --- Close Others (right-click tab 1, "b.txt") ----------------------
    app = TabMenuTestApp.new(files)
    app.i18n.locale = "en"
    ctx = Egui::Context.new
    3.times { |i| tmenu_frame(app, ctx, time: 0.016 * (i + 1)) }
    app.docs.map(&.title).should eq(["a.txt", "b.txt", "c.txt", "d.txt"])

    pos = tmenu_tab_center(ctx, app.docs.map(&.title), 1)
    tmenu_frame(app, ctx, events: [Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos, :secondary)], time: 0.1)
    cmds = tmenu_frame(app, ctx, time: 0.12) # menu item rects registered
    tmenu_click_text(cmds, app, ctx, "Close Others", 0.14).should be_true
    tmenu_frame(app, ctx, time: 0.16)
    app.docs.map(&.title).should eq(["b.txt"])

    # --- Close Tabs to the Right (right-click tab 1) ---------------------
    app2 = TabMenuTestApp.new(files)
    app2.i18n.locale = "en"
    ctx2 = Egui::Context.new
    3.times { |i| tmenu_frame(app2, ctx2, time: 0.016 * (i + 1)) }
    pos = tmenu_tab_center(ctx2, app2.docs.map(&.title), 1)
    tmenu_frame(app2, ctx2, events: [Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos, :secondary)], time: 0.1)
    cmds = tmenu_frame(app2, ctx2, time: 0.12)
    tmenu_click_text(cmds, app2, ctx2, "Close Tabs to the Right",
      0.14).should be_true
    tmenu_frame(app2, ctx2, time: 0.16)
    app2.docs.map(&.title).should eq(["a.txt", "b.txt"])

    # --- Close All -------------------------------------------------------
    app3 = TabMenuTestApp.new(files)
    app3.i18n.locale = "en"
    ctx3 = Egui::Context.new
    3.times { |i| tmenu_frame(app3, ctx3, time: 0.016 * (i + 1)) }
    pos = tmenu_tab_center(ctx3, app3.docs.map(&.title), 0)
    tmenu_frame(app3, ctx3, events: [Egui::Event.pointer_moved(pos),
      Egui::Event.pointer_pressed(pos, :secondary)], time: 0.1)
    cmds = tmenu_frame(app3, ctx3, time: 0.12)
    tmenu_click_text(cmds, app3, ctx3, "Close All Tabs", 0.14).should be_true
    tmenu_frame(app3, ctx3, time: 0.16)
    app3.docs.size.should eq(0)
  end
end
