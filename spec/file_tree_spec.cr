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
# *cursor*/*on_cursor* round-trip the app-owned keyboard cursor.
def key_frame(ctx : Egui::Context, dir : String, keys : Array(Egui::KeyCode),
              cursor : String = "", on_cursor : (String ->)? = nil,
              &on_activate : String ->)
  raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
    Egui::Vec2.new(300.0, 600.0)))
  raw.events = keys.map { |k| Egui::Event.key_pressed(k) }
  ctx.begin_frame(raw)
  ctx.central_panel do |ui|
    ui.file_tree("x", dir, cursor: cursor, on_cursor: on_cursor) { |path|
      on_activate.call(path)
    }
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

      # mtime granularity + the RECHECK throttle: wait past both, then
      # force a change the cache can see.
      sleep Kodkod::FileTree::RECHECK + 0.02.seconds
      File.touch(File.join(dir, "b.txt"))
      Kodkod::FileTree.listing(dir).map(&.name)
        .should eq(["a.txt", "b.txt"])

      Kodkod::FileTree.refresh
      Kodkod::FileTree.listing(dir).same?(first).should be_false
    end
  end

  {% if flag?(:linux) %}
    it "refreshes listings from fs events without waiting for RECHECK" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Kodkod::FileTree.refresh
        File.touch(File.join(dir, "a.txt"))
        # One rendered frame arms the recursive FSWatch on the root
        # (ensure_watch in `ui`); the cache entry follows.
        ctx.begin_frame(Egui::RawInput.new(
          Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(300.0, 600.0))))
        ctx.central_panel do |ui|
          ui.file_tree("fs-events", dir) { |_path| }
        end
        ctx.end_frame
        Kodkod::FileTree.listing(dir)

        # The event lands asynchronously (the shard's observation
        # fiber); poll WELL under RECHECK — the point is that no poll
        # wait is needed.
        File.touch(File.join(dir, "b.txt"))
        deadline = Time.instant + 2.seconds
        until Kodkod::FileTree.listing(dir).map(&.name).size == 2
          sleep 0.02.seconds
          raise "fs event never arrived" if Time.instant > deadline
        end
        Kodkod::FileTree.listing(dir).map(&.name)
          .should eq(["a.txt", "b.txt"])

        # Deletions invalidate too.
        File.delete(File.join(dir, "a.txt"))
        until Kodkod::FileTree.listing(dir).map(&.name).size == 1
          sleep 0.02.seconds
          raise "fs delete event never arrived" if Time.instant > deadline
        end
      end
    end
  {% end %}

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

  # Keyboard navigation: the cursor is APP STATE (`cursor:`/`on_cursor:`
  # — a reactive in the app), not widget focus. The tree drives the
  # arrows while no other widget holds egui focus and no modal is up.
  describe "keyboard" do
    it "Enter toggles the cursor directory row" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Dir.mkdir(File.join(dir, "src"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_id = base.child(Egui::Id.from(File.join(dir, "src")).value)
        ctx.memory.data.set_bool(root_id, true)

        cursor = File.join(dir, "src")
        noop = ->(_p : String) { }
        key_frame(ctx, dir, [Egui::KeyCode::Enter], cursor) { |p| noop.call(p) }
        ctx.memory.data.get_bool(src_id, false).should be_true
        key_frame(ctx, dir, [Egui::KeyCode::Enter], cursor) { |p| noop.call(p) }
        ctx.memory.data.get_bool(src_id, false).should be_false
      end
    end

    it "Enter activates the cursor file row" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        File.touch(File.join(dir, "main.cr"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        ctx.memory.data.set_bool(root_id, true)

        opened = nil
        cb = ->(p : String) { opened = p }
        key_frame(ctx, dir, [Egui::KeyCode::Enter],
          File.join(dir, "main.cr")) { |p| cb.call(p) }
        opened.should eq(File.join(dir, "main.cr"))
      end
    end

    it "ignores the keyboard while the cursor is unarmed" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        File.touch(File.join(dir, "a.txt"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        ctx.memory.data.set_bool(root_id, true)

        moved = ""
        cb = ->(p : String) { moved = p }
        key_frame(ctx, dir, [Egui::KeyCode::Down], "", cb) { |_p| }
        moved.should be_empty
      end
    end

    it "ignores the keyboard while another widget holds focus" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        File.touch(File.join(dir, "a.txt"))
        File.touch(File.join(dir, "b.txt"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        ctx.memory.data.set_bool(root_id, true)

        field = ""
        moved = ""
        cb = ->(p : String) { moved = p }
        frame = ->(keys : Array(Egui::KeyCode)) do
          raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(300.0, 600.0)))
          raw.events = keys.map { |k| Egui::Event.key_pressed(k) }
          ctx.begin_frame(raw)
          ctx.central_panel do |ui|
            r = ui.text_edit_singleline(field, focus_id: "f") { |t| field = t }
            r.try(&.request_focus) # the editor stand-in holds focus
            ui.file_tree("x", dir, cursor: File.join(dir, "a.txt"),
              on_cursor: cb) { |_p| }
          end
          ctx.end_frame
        end

        frame.call([] of Egui::KeyCode) # the field takes focus
        frame.call([] of Egui::KeyCode)
        ctx.memory.focus.id.should_not be_nil
        frame.call([Egui::KeyCode::Down])
        moved.should be_empty
      end
    end

    it "Up/Down walk the VISIBLE tree in display order, one step per press" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        # root → src (open) → deep (collapsed), a.cr, zebra.txt — the
        # walk order is exactly the display order (folders first),
        # nested rows included.
        Dir.mkdir_p(File.join(dir, "src", "deep"))
        File.touch(File.join(dir, "src", "a.cr"))
        File.touch(File.join(dir, "zebra.txt"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_row_id = base.child(Egui::Id.from(File.join(dir, "src")).value)
        src_id = File.join(dir, "src")
        a_id = File.join(dir, "src", "a.cr")
        deep_id = File.join(dir, "src", "deep")
        zebra_id = File.join(dir, "zebra.txt")
        ctx.memory.data.set_bool(root_id, true)
        ctx.memory.data.set_bool(src_row_id, true)

        cursor = dir
        cb = ->(p : String) { cursor = p }
        step = ->(keys : Array(Egui::KeyCode)) do
          key_frame(ctx, dir, keys, cursor, cb) { |_p| }
        end

        # Down through every visible row, in order; batching two
        # presses into one frame takes two steps.
        step.call([Egui::KeyCode::Down])
        cursor.should eq(src_id)
        step.call([Egui::KeyCode::Down])
        cursor.should eq(deep_id)
        step.call([Egui::KeyCode::Down, Egui::KeyCode::Down])
        cursor.should eq(zebra_id)

        # Down past the last row is a no-op.
        step.call([Egui::KeyCode::Down])
        cursor.should eq(zebra_id)

        step.call([Egui::KeyCode::Up])
        cursor.should eq(a_id)
        step.call([Egui::KeyCode::Up, Egui::KeyCode::Up])
        cursor.should eq(src_id)
      end
    end

    it "Right expands a collapsed folder, then descends into it" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Dir.mkdir(File.join(dir, "src"))
        File.touch(File.join(dir, "src", "a.cr"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_id = base.child(Egui::Id.from(File.join(dir, "src")).value)
        a_id = File.join(dir, "src", "a.cr")
        ctx.memory.data.set_bool(root_id, true)

        cursor = File.join(dir, "src")
        cb = ->(p : String) { cursor = p }
        step = ->(keys : Array(Egui::KeyCode)) do
          key_frame(ctx, dir, keys, cursor, cb) { |_p| }
        end

        # Collapsed: Right opens it (the cursor stays on the folder).
        ctx.memory.data.get_bool(src_id, false).should be_false
        step.call([Egui::KeyCode::Right])
        ctx.memory.data.get_bool(src_id, false).should be_true
        cursor.should eq(File.join(dir, "src"))

        # Open: Right steps to the first child row.
        step.call([Egui::KeyCode::Right])
        cursor.should eq(a_id)

        # On a FILE Right is a no-op.
        step.call([Egui::KeyCode::Right])
        cursor.should eq(a_id)
      end
    end

    it "Left collapses an open folder, or climbs to the parent row" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Dir.mkdir_p(File.join(dir, "src", "deep"))
        File.touch(File.join(dir, "src", "deep", "a.cr"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_id = base.child(Egui::Id.from(File.join(dir, "src")).value)
        deep_row_id = base.child(
          Egui::Id.from(File.join(dir, "src", "deep")).value)
        deep_id = File.join(dir, "src", "deep")
        a_id = File.join(dir, "src", "deep", "a.cr")
        [root_id, src_id, deep_row_id].each do |id|
          ctx.memory.data.set_bool(id, true)
        end

        cursor = a_id
        cb = ->(p : String) { cursor = p }
        step = ->(keys : Array(Egui::KeyCode)) do
          key_frame(ctx, dir, keys, cursor, cb) { |_p| }
        end

        # On a file Left climbs to the parent row.
        step.call([Egui::KeyCode::Left])
        cursor.should eq(deep_id)

        # On an open folder Left collapses it (the cursor stays).
        ctx.memory.data.get_bool(deep_row_id, false).should be_true
        step.call([Egui::KeyCode::Left])
        ctx.memory.data.get_bool(deep_row_id, false).should be_false
        cursor.should eq(deep_id)

        # Collapsed: Left climbs to the parent again.
        step.call([Egui::KeyCode::Left])
        cursor.should eq(File.join(dir, "src"))

        # Left on the OPEN root row collapses it — there is no parent
        # row to climb to, and the cursor stays put.
        cursor = dir
        step.call([Egui::KeyCode::Left])
        ctx.memory.data.get_bool(root_id, true).should be_false
        cursor.should eq(dir)
      end
    end

    it "a click arms the cursor and the arrows follow it" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        Dir.mkdir(File.join(dir, "src"))
        File.touch(File.join(dir, "a.txt"))
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        src_id = File.join(dir, "src")
        a_id = File.join(dir, "a.txt")
        ctx.memory.data.set_bool(root_id, true)

        cursor = ""
        cb = ->(p : String) { cursor = p }
        frame = ->(events : Array(Egui::Event)) do
          raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(300.0, 600.0)))
          raw.events = events
          ctx.begin_frame(raw)
          ctx.central_panel do |ui|
            ui.file_tree("x", dir, cursor: cursor, on_cursor: cb) { |_p| }
          end
          ctx.end_frame
        end

        # Click the src row (dirs sort first; row text centers sit at
        # ~21 / ~48 in the default central panel — see the probe in
        # the spec history).
        frame.call([] of Egui::Event) # register row geometry for hit-testing
        pos = Egui::Pos2.new(30.0, 48.0)
        frame.call([Egui::Event.pointer_moved(pos),
                    Egui::Event.pointer_pressed(pos)] of Egui::Event)
        frame.call([Egui::Event.pointer_released(pos)] of Egui::Event)
        cursor.should eq(src_id)

        # The keyboard picks up from the clicked row immediately.
        frame.call([Egui::Event.key_pressed(Egui::KeyCode::Down)] of Egui::Event)
        cursor.should eq(a_id)
      end
    end

    it "scrolls the cursor row into view" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        40.times { |i| File.touch(File.join(dir, "f%02d.txt" % i)) }
        base = Egui::Id.from("kodkod/file_tree/x")
        root_id = base.child(Egui::Id.from(dir).value)
        scroll_id = base.child(Egui::Id.from("scroll").value)
        ctx.memory.data.set_bool(root_id, true)

        # A short window: only a few of the 41 rows fit the viewport.
        cursor = dir
        cb = ->(p : String) { cursor = p }
        frame = ->(keys : Array(Egui::KeyCode)) do
          raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
            Egui::Vec2.new(300.0, 120.0)))
          raw.events = keys.map { |k| Egui::Event.key_pressed(k) }
          ctx.begin_frame(raw)
          ctx.central_panel do |ui|
            ui.file_tree("x", dir, cursor: cursor, on_cursor: cb) { |_p| }
          end
          ctx.end_frame
        end

        frame.call([] of Egui::KeyCode)
        ctx.memory.data.get_vec2(scroll_id).y.should eq(0.0)

        8.times { frame.call([Egui::KeyCode::Down]) }
        ctx.memory.data.get_vec2(scroll_id).y.should be > 0.0
      end
    end

    it "keeps the user's scroll while the cursor merely stays" do
      ctx = Egui::Context.new
      with_temp_dir do |dir|
        40.times { |i| File.touch(File.join(dir, "f%02d.txt" % i)) }
        base = Egui::Id.from("kodkod/file_tree/x")
        scroll_id = base.child(Egui::Id.from("scroll").value)

        raw = Egui::RawInput.new(Egui::Rect.from_min_size(Egui::Pos2.zero,
          Egui::Vec2.new(300.0, 120.0)))
        cursor = File.join(dir, "f00.txt")
        frame = -> do
          ctx.begin_frame(raw)
          ctx.central_panel do |ui|
            ui.file_tree("x", dir, cursor: cursor) { |_p| }
          end
          ctx.end_frame
        end

        frame.call # the cursor row renders and settles

        # The user scrolls the tree away from the cursor row; the
        # viewport must NOT be pulled back on the following frames.
        ctx.memory.data.set_vec2(scroll_id, Egui::Vec2.new(0.0, 500.0))
        3.times { frame.call }
        ctx.memory.data.get_vec2(scroll_id).y.should eq(500.0)
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
