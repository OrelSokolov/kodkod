require "spec"
require "file_utils"
require "../src/file_tree"

# A Ruby-style mktempdir (Crystal has none): unique dir under the
# system tempdir, removed after the block.
def with_temp_dir(& : String ->)
  dir = File.join(Dir.tempdir,
    "kodkod-spec-#{Random.new.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_r(dir) rescue nil
  end
end

describe Kodkod::FileTree do
  it "lists directories first, then files, alphabetically (case-blind)" do
    with_temp_dir do |dir|
      File.touch(File.join(dir, "zebra.cr"))
      File.touch(File.join(dir, "Apple.txt"))
      Dir.mkdir(File.join(dir, "src"))
      File.touch(File.join(dir, ".hidden"))
      entries = Kodkod::FileTree.listing(dir)
      # Raw listing keeps hidden files — the widget filters them at
      # render time through `show_hidden:`.
      entries.map(&.name).should eq(["src", ".hidden", "Apple.txt", "zebra.cr"])
      entries[0].dir.should be_true
      entries[1].dir.should be_false
    end
  end

  it "caches listings and refresh drops them" do
    with_temp_dir do |dir|
      Kodkod::FileTree.refresh
      File.touch(File.join(dir, "a.txt"))
      first = Kodkod::FileTree.listing(dir)
      first.same?(Kodkod::FileTree.listing(dir)).should be_true

      # mtime granularity: force a change the cache can see.
      sleep 0.01
      File.touch(File.join(dir, "b.txt"))
      Kodkod::FileTree.listing(dir).map(&.name)
        .should eq(["a.txt", "b.txt"])

      Kodkod::FileTree.refresh
      Kodkod::FileTree.listing(dir).same?(first).should be_false
    end
  end

  it "renders a frame with an expanded root without raising" do
    ctx = Egui::Context.new
    with_temp_dir do |dir|
      File.touch(File.join(dir, "main.cr"))
      Dir.mkdir(File.join(dir, "lib"))
      # Pre-expand the root through the same memory cell the widget
      # uses (id = base.child(Id.from(path).value)).
      base = Egui::Id.from("kodkod/file_tree/x")
      ctx.memory.data.set_bool(base.child(Egui::Id.from(dir).value), true)

      ctx.begin_frame(Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero,
          Egui::Vec2.new(300.0, 600.0))))
      ctx.central_panel do |ui|
        ui.scroll_area do |sui|
          sui.file_tree("x", dir) { |_path| }
        end
      end
      ctx.end_frame # children of the root were walked — no raise
    end
  end

  it "selection highlight spans to the region's right edge at any depth" do
    ctx = Egui::Context.new
    with_temp_dir do |dir|
      Dir.mkdir_p(File.join(dir, "sub", "deep"))
      sel = File.join(dir, "sub", "deep", "file.cr")
      File.touch(sel)
      # Pre-expand root → sub → deep through the widget's memory cells.
      base = Egui::Id.from("kodkod/file_tree/x")
      [dir, File.join(dir, "sub"), File.join(dir, "sub", "deep")].each do |p|
        ctx.memory.data.set_bool(base.child(Egui::Id.from(p).value), true)
      end

      ctx.begin_frame(Egui::RawInput.new(
        Egui::Rect.from_min_size(Egui::Pos2.zero,
          Egui::Vec2.new(300.0, 600.0))))
      ctx.central_panel do |ui|
        ui.scroll_area do |sui|
          sui.file_tree("x", dir, active: sel) { |_path| }
        end
      end
      ctx.end_frame

      # The active row (depth 2) paints a selection_fill rect; its
      # right edge must reach the visible region's right edge — the
      # depth indent must not shorten the highlight before long names.
      fill = ctx.style.visuals.selection_fill
      rects = ctx.painter.commands.select(Egui::RectCmd)
        .select { |c| c.fill == fill }
      rects.should_not be_empty
      rects.each do |c|
        c.rect.right.should be_close(c.clip.right, 0.5)
      end
    end
  end

  it "paints last_touched dimmer than active and drops it on activate" do
    ctx = Egui::Context.new
    with_temp_dir do |dir|
      Dir.mkdir(File.join(dir, "src"))
      File.touch(File.join(dir, "src", "a.cr"))
      base = Egui::Id.from("kodkod/file_tree/x")
      ctx.memory.data.set_bool(base.child(Egui::Id.from(dir).value), true)
      lt_id = base.child(Egui::Id.from("last_touched").value)

      render = ->(active : String?) do
        ctx.begin_frame(Egui::RawInput.new(
          Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(300.0, 600.0))))
        ctx.central_panel do |ui|
          ui.scroll_area do |sui|
            sui.file_tree("x", dir, active: active) { |_path| }
          end
        end
        ctx.end_frame
      end

      # A touched directory (never becoming active) keeps the dim
      # fill; the highlight spans to the region's right edge.
      ctx.memory.data.set_string(lt_id, File.join(dir, "src"))
      render.call(nil)
      v = ctx.style.visuals
      dim = v.fade_color(v.selection_fill, 0.6)
      rects = ctx.painter.commands.select(Egui::RectCmd)
        .select { |c| c.fill == dim }
      rects.should_not be_empty
      rects.each do |c|
        c.rect.right.should be_close(c.clip.right, 0.5)
      end
      ctx.memory.data.get_string(lt_id)
        .should eq(File.join(dir, "src"))

      # The touched row graduating to active drops the touch: only
      # the full selection_fill remains, and the cell is cleared.
      render.call(File.join(dir, "src"))
      ctx.painter.commands.select(Egui::RectCmd)
        .select { |c| c.fill == dim }.should be_empty
      ctx.painter.commands.select(Egui::RectCmd)
        .select { |c| c.fill == v.selection_fill }.should_not be_empty
      ctx.memory.data.get_string(lt_id).should be_empty
    end
  end
end
