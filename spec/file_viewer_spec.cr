require "spec"
require "../src/file_viewer"
require "../src/app"

# Exposes the private doc list for the app-routing spec below.
class ViewerTestApp < KodkodApp
  def docs; @docs; end
end

VSCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(800.0, 600.0))

# One frame of the viewer on a SHARED context — click memory (double
# clicks) and texture state must survive between frames.
def viewer_frame(viewer : Kodkod::FileViewer, ctx : Egui::Context,
                 events : Array(Egui::Event) = [] of Egui::Event,
                 time : Float64 = 0.016)
  ctx.begin_frame(Egui::RawInput.new(VSCREEN, events, time))
  ctx.central_panel do |ui|
    viewer.show(ui)
  end
  ctx.end_frame
end

describe Kodkod::FileViewer do
  it "classifies supported files by extension" do
    Kodkod::FileViewer.supported?("a/b.png").should be_true
    Kodkod::FileViewer.supported?("a/b.SVG").should be_true
    Kodkod::FileViewer.supported?("a/b.jpg").should be_true
    Kodkod::FileViewer.supported?("a/b.cr").should be_false
    Kodkod::FileViewer.supported?("noext").should be_false
  end

  it "parses an SVG's intrinsic size at open" do
    path = File.tempname("kodkod", ".svg")
    File.write(path, %(<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="10" height="10" fill="red"/></svg>))
    begin
      v = Kodkod::FileViewer.new(path)
      v.error.should be_nil
      v.svg?.should be_true
      i = v.intrinsic.not_nil!
      i.x.should eq(120.0)
      i.y.should eq(80.0)
      v.status_info.should contain("SVG")
      v.status_info.should contain("120×80")
      v.status_info.should contain("100%")
      # headless frames render nothing but must not crash
      viewer_frame(v, Egui::Context.new)
    ensure
      File.delete(path)
    end
  end

  it "reports a broken SVG as an error tab, not a crash" do
    path = File.tempname("kodkod", ".svg")
    File.write(path, "not an svg at all")
    begin
      v = Kodkod::FileViewer.new(path)
      v.error.should_not be_nil
      viewer_frame(v, Egui::Context.new)
    ensure
      File.delete(path)
    end
  end

  it "reports a missing file as an error tab" do
    v = Kodkod::FileViewer.new("/nonexistent/kodkod.svg")
    v.error.should_not be_nil
    viewer_frame(v, Egui::Context.new)
  end

  it "rejects unsupported extensions" do
    path = File.tempname("kodkod", ".cr")
    File.write(path, "puts 1")
    begin
      v = Kodkod::FileViewer.new(path)
      v.error.not_nil!.should contain("Cannot view this file")
    ensure
      File.delete(path)
    end
  end

  # The app-level routing: unsupported files open as an explaining
  # viewer tab (not a silent skip); text still reaches the editor.
  it "routes files through KodkodApp.open wiring" do
    app_ctx = Egui::Context.new # the app paints on first update
    bin = File.tempname("kodkod", ".bin")
    File.write(bin, Bytes.new(64) { |i| (i * 37 % 251).to_u8 })
    empty = File.tempname("kodkod", ".txt")
    File.write(empty, "")
    begin
      app = ViewerTestApp.new([bin, empty, "spec/file_viewer_spec.cr"])
      app.update(app_ctx)
      docs = app.docs
      docs.size.should eq(3)
      docs[0].viewer?.should_not be_nil # binary → viewer tab…
      docs[0].viewer?.not_nil!.error.not_nil!
             .should contain("Cannot view this file")
      docs[1].buffer?.should_not be_nil # empty file → editor
      docs[2].buffer?.should_not be_nil # text → editor
    ensure
      File.delete(bin)
      File.delete(empty)
    end
  end

  it "zooms on the wheel and resets on a double-click" do
    path = File.tempname("kodkod", ".svg")
    File.write(path, %(<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="10" height="10"/></svg>))
    begin
      v = Kodkod::FileViewer.new(path)
      ctx = Egui::Context.new
      # wheel-up over the pane zooms in, wheel-down zooms back out
      events = [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0)),
                Egui::Event.scroll(Egui::Vec2.new(0.0, -1.0))]
      viewer_frame(v, ctx, events)
      v.zoom.should be > 1.0
      events = [Egui::Event.pointer_moved(Egui::Pos2.new(400.0, 300.0)),
                Egui::Event.scroll(Egui::Vec2.new(0.0, 1.0))]
      viewer_frame(v, ctx, events)
      v.zoom.should be < 1.0 + 1e-9
      # double-click resets to the fitted view (click classification
      # is one release per frame — two frames, within the interval)
      v.zoom = 4.0
      pos = Egui::Pos2.new(400.0, 300.0)
      click = [Egui::Event.pointer_moved(pos),
               Egui::Event.pointer_pressed(pos),
               Egui::Event.pointer_released(pos)]
      viewer_frame(v, ctx, click, time: 0.1)
      viewer_frame(v, ctx, click, time: 0.2)
      v.zoom.should eq(1.0)
    ensure
      File.delete(path)
    end
  end
end
