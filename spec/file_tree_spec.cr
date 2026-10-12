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

# Drive one frame of a FileTree over *dir* with raw key presses (the
# keyboard-navigation specs); *on_activate* receives activated files.
def key_frame(ctx : Egui::Context, dir : String, keys : Array(Egui::KeyCode),
              &on_activate : String ->)
  raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
    Egui::Vec2.new(300.0, 600.0)))
  raw.events = keys.map { |k| Egui::Event.key_pressed(k) }
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.file_tree("x", dir) { |path| on_activate.call(path) }
  end
  ctx.end_frame
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
        ui.file_tree("x", dir) { |_path| }
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
        ui.file_tree("x", dir, active: sel) { |_path| }
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
          ui.file_tree("x", dir, active: active) { |_path| }
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

  it "reveals the active file reactively: expands ancestors, scrolls, once" do
    ctx = Egui::Context.new
    with_temp_dir do |dir|
      Dir.mkdir(File.join(dir, "sub"))
      # Directories sort first, so the off-screen target must be a
      # LATE row: the last of sub/'s files.
      40.times { |i| File.touch(File.join(dir, "sub", "g%02d.cr" % i)) }
      sel = File.join(dir, "sub", "g39.cr")
      base = Egui::Id.from("kodkod/file_tree/x")
      sub_id = base.child(Egui::Id.from(File.join(dir, "sub")).value)
      scroll_id = base.child(Egui::Id.from("scroll").value)

      # A short window: the deep row is off-screen at offset 0.
      raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
        Egui::Vec2.new(300.0, 120.0)))
      frame = ->(active : String?) do
        ctx.begin_frame(raw)
        ctx.central_panel do |ui|
          ui.file_tree("x", dir, active: active) { |_p| }
        end
        ctx.end_frame
      end

      frame.call(nil) # register rows; nothing expanded, nothing scrolled
      ctx.memory.data.get_bool(sub_id, false).should be_false
      ctx.memory.data.get_vec2(scroll_id).y.should eq(0.0)

      # A NEW active path: `sub` opens and the row scrolls into view.
      frame.call(sel)
      ctx.memory.data.get_bool(sub_id, false).should be_true
      ctx.memory.data.get_vec2(scroll_id).y.should be > 0.0

      # Same active next frame: no re-reveal — the user's own
      # scrolling is not fought.
      ctx.memory.data.set_vec2(scroll_id, Egui::Vec2.zero)
      frame.call(sel)
      ctx.memory.data.get_vec2(scroll_id).y.should eq(0.0)
    end
  end

  # Keyboard navigation: rows are focusable, Up/Down walk them, Enter
  # acts like a click. Row node ids come from the same scheme the
  # widget uses (base.child(Id.from(path).value)); focus requests are
  # applied on the FOLLOWING frame's begin_frame.
  describe "keyboard" do
    it "Enter toggles the focused directory row" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Dir.mkdir(File.join(dir, "src"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_id = base.child(Egui::Id.from(File.join(dir, "src")).value)
        ctx.memory.data.set_bool(root_id, true)

        key_frame(ctx, dir, [] of Egui::KeyCode) { |_p| } # register rows
        ctx.memory.focus.request(src_id)                  # cursor on src/
        key_frame(ctx, dir, [] of Egui::KeyCode) { |_p| } # focus takes hold
        ctx.memory.data.get_bool(src_id, false).should be_false

        key_frame(ctx, dir, [Egui::KeyCode::Enter]) { |_p| } # open
        ctx.memory.data.get_bool(src_id, false).should be_true
        key_frame(ctx, dir, [Egui::KeyCode::Enter]) { |_p| } # close
        ctx.memory.data.get_bool(src_id, false).should be_false
      end
    end

    it "Enter activates the focused file row" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        File.touch(File.join(dir, "main.cr"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        file_id = base.child(Egui::Id.from(File.join(dir, "main.cr")).value)
        ctx.memory.data.set_bool(root_id, true)

        opened = nil
        cb = ->(p : String) { opened = p }
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| cb.call(p) }
        ctx.memory.focus.request(file_id)
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| cb.call(p) }
        opened.should be_nil

        key_frame(ctx, dir, [Egui::KeyCode::Enter]) { |p| cb.call(p) }
        opened.should eq(File.join(dir, "main.cr"))
      end
    end

    it "Up/Down walk the rows" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Dir.mkdir(File.join(dir, "src"))
        File.touch(File.join(dir, "zebra.txt"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_id = base.child(Egui::Id.from(File.join(dir, "src")).value)
        zebra_id = base.child(Egui::Id.from(File.join(dir, "zebra.txt")).value)
        ctx.memory.data.set_bool(root_id, true)

        noop = ->(_p : String) {}
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| noop.call(p) }
        ctx.memory.focus.request(root_id)
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| noop.call(p) }

        # Each arrow moves one row; focus.id updates on the FOLLOWING
        # frame's begin_frame (navigate_focus requests, Focus applies).
        key_frame(ctx, dir, [Egui::KeyCode::Down]) { |p| noop.call(p) }
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| noop.call(p) }
        ctx.memory.focus.id.should eq(src_id)

        key_frame(ctx, dir, [Egui::KeyCode::Down]) { |p| noop.call(p) }
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| noop.call(p) }
        ctx.memory.focus.id.should eq(zebra_id)

        key_frame(ctx, dir, [Egui::KeyCode::Up]) { |p| noop.call(p) }
        key_frame(ctx, dir, [] of Egui::KeyCode) { |p| noop.call(p) }
        ctx.memory.focus.id.should eq(src_id)
      end
    end

    it "scrolls the focused row into view" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        40.times { |i| File.touch(File.join(dir, "f%02d.txt" % i)) }
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        ctx.memory.data.set_bool(root_id, true)
        scroll_id = base.child(Egui::Id.from("scroll").value)

        # A short window: only a few of the 41 rows fit the viewport.
        raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
          Egui::Vec2.new(300.0, 120.0)))
        frame = ->(keys : Array(Egui::KeyCode)) do
          raw.events = keys.map { |k| Egui::Event.key_pressed(k) }
          ctx.begin_frame(raw)
          ctx.central_panel do |ui|
            ui.file_tree("x", dir) { |_p| }
          end
          ctx.end_frame
        end

        frame.call([] of Egui::KeyCode)
        ctx.memory.focus.request(root_id)
        frame.call([] of Egui::KeyCode)
        ctx.memory.data.get_vec2(scroll_id).y.should eq(0.0)

        8.times { frame.call([Egui::KeyCode::Down]) }
        ctx.memory.data.get_vec2(scroll_id).y.should be > 0.0
      end
    end
  end
end

describe "FileTree font zoom" do
  it "Ctrl+Minus/Equal zoom the tree font on hover, whole points only" do
    ctx = Egui::Context.new
    with_temp_dir do |dir|
      File.touch(File.join(dir, "a.txt"))
      cell = Egui::Id.from("kodkod/file_tree/x")
        .child(Kodkod::FileTree::FONT_SALT)
      ctrl = Egui::Modifiers.new(ctrl: true)
      inside = Egui::Pos2.new(150.0, 100.0)
      zoom_frame = ->(key : Egui::KeyCode?, pos : Egui::Pos2) do
        events = [Egui::Event.pointer_moved(pos)] of Egui::Event
        events << Egui::Event.key_pressed(key, ctrl) if key
        raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
          Egui::Vec2.new(300.0, 600.0)))
        raw.events = events
        ctx.begin_frame(raw)
        ctx.central_panel do |ui|
          ui.file_tree("x", dir) { |_p| }
        end
        ctx.end_frame
      end

      zoom_frame.call(nil, inside) # register rows; no override yet
      ctx.memory.data.get_f64(cell).should eq(0.0)
      zoom_frame.call(Egui::KeyCode::Minus, inside) # 16.0 → 15.0
      ctx.memory.data.get_f64(cell).should eq(15.0)
      zoom_frame.call(Egui::KeyCode::Equal, inside)
      ctx.memory.data.get_f64(cell).should eq(16.0)

      # Off the tree the keys do nothing.
      away = Egui::Pos2.new(-50.0, -50.0)
      zoom_frame.call(Egui::KeyCode::Minus, away)
      ctx.memory.data.get_f64(cell).should eq(16.0)
    end
  end
end
