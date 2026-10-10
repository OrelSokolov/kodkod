# kodkod — FileTree: a lazy-loading file explorer widget.
#
# TreeView builds its rows from an app-supplied block every frame; a
# directory tree wants the opposite — rows COME from the filesystem,
# read only when a node is first expanded (a repo with 10k files must
# not stat anything until asked). Directory listings are cached per
# path with an mtime check, so re-expanding is free and F5/`refresh`
# drops the cache wholesale.
#
# Expand state lives in Memory#data keyed by the entry's absolute path
# id — surviving frames like TreeView, no app-held state. Rows carry
# two highlight states: `active` (the app-supplied open file, full
# selection fill) and `last_touched` — the last clicked row that did
# NOT become active (a toggled directory, a file the app declined to
# open), painted as a dimmer fill. Every click records the touch in
# Memory#data; once the touched row graduates to `active`, the touch
# is forgotten. Icons are
# compile-time-embedded lucide SVGs: folder / folder-open for
# directories, a per-extension map for files, `file` as the fallback.
#
# KEYBOARD: rows are Sense::Focusable, so egui's geometric focus
# navigation walks them with Up/Down (a focused row requests focus on
# click, too), and Enter on the focused row acts exactly like a click
# — toggling a directory, activating a file. The widget owns its
# ScrollArea (stable id under `base`) so the focused row can be
# scrolled into view after the arrows walk it off-screen.

require "egui-cr/egui"

module Kodkod
  class FileTree
    record Entry, name : String, dir : Bool

    class Listing
      property mtime : Time?
      property entries : Array(Entry)

      def initialize(@mtime : Time?, @entries : Array(Entry))
      end
    end

    # path => listing; bounded by the number of directories ever
    # expanded this session. Keyed by the REAL expanded path — the
    # hidden-file filter is applied at render, so toggling it back and
    # forth never re-stats.
    @@listings = {} of String => Listing

    def self.refresh : Nil
      @@listings.clear
    end

    def self.listing(dir : String) : Array(Entry)
      mtime = File.info?(dir).try(&.modification_time)
      if (cached = @@listings[dir]?) && cached.mtime == mtime
        return cached.entries
      end
      entries = Dir.children(dir).reject { |n| n == ".git" }.map do |n|
        Entry.new(n, File.directory?(File.join(dir, n)))
      end.sort_by! do |e|
        {e.dir ? 0 : 1, e.name.downcase}
      end
      @@listings[dir] = Listing.new(mtime, entries)
      entries
    end

    # Extension → lucide icon name. Everything missing from the map
    # falls back to the plain `file` icon.
    EXT_ICONS = {
      ".cr" => :file_code, ".rb" => :file_code, ".py" => :file_code,
      ".rs" => :file_code, ".c" => :file_code, ".h" => :file_code,
      ".cc" => :file_code, ".cpp" => :file_code, ".js" => :file_code,
      ".ts" => :file_code, ".go" => :file_code, ".java" => :file_code,
      ".zig" => :file_code, ".sql" => :file_code,
      ".sh" => :file_terminal, ".bash" => :file_terminal,
      ".zsh" => :file_terminal, ".fish" => :file_terminal,
      ".json" => :braces, ".yml" => :braces, ".yaml" => :braces,
      ".toml" => :braces, ".xml" => :braces, ".pem" => :braces,
      ".md" => :file_text, ".txt" => :file_text, ".log" => :file_text,
      ".lock" => :file_text, ".conf" => :file_text, ".ini" => :file_text,
      ".png" => :file_image, ".jpg" => :file_image, ".jpeg" => :file_image,
      ".gif" => :file_image, ".svg" => :file_image, ".webp" => :file_image,
      ".bmp" => :file_image, ".ico" => :file_image,
      ".zip" => :file_archive, ".tar" => :file_archive,
      ".gz" => :file_archive, ".xz" => :file_archive,
      ".a" => :file_archive, ".o" => :file_archive, ".so" => :file_archive,
      ".wasm" => :file_archive,
    }

    ICON_SIZE = 16.0
    CHEVRON_W = 14.0
    INDENT = 14.0
    FONT_SALT = 0xF017_u64 # Ctrl +/- font zoom override
    FONT_MIN = 8.0
    FONT_MAX = 40.0

    def initialize(@id : String)
    end

    def ui(ui : Egui::Ui, root : String, active : String? = nil,
           show_hidden : Bool = false, chevrons : Bool = true,
           &on_activate : String ->) : Nil
      memory = ui.ctx.memory
      base = Egui::Id.from("kodkod/file_tree/#{@id}")
      @on_activate = on_activate
      @last_touched_id = lt_id = base.child(Egui::Id.from("last_touched").value)
      memory.use_id(lt_id) # survive end-frame pruning
      @last_touched = memory.data.get_string(lt_id)
      if active && @last_touched == active
        @last_touched = ""
        memory.data.set_string(lt_id, "")
      end
      # The tree scrolls in its OWN area (a stable id under `base`) so
      # the focused row's rect, recorded during the walk, can be
      # brought into view afterwards (see scroll_focus_into_view).
      @focus_rect = nil
      scroll_id = base.child(Egui::Id.from("scroll").value)
      viewport = Egui::ScrollArea.new(id: scroll_id).show(ui) do |inner|
        with_zoom(inner, base) do
          walk(inner, memory, base, root, 0, active, show_hidden, chevrons)
        end
      end
      scroll_focus_into_view(ui.ctx, memory, scroll_id, viewport)
    end

    # Keep the focused row inside the viewport after arrow navigation:
    # the walk recorded its rect (screen coords); shifted into content
    # space it must land in [offset.y, offset.y + viewport.height], with
    # one row of context kept above/below. Writing the offset cell
    # directly is picked up by the ScrollArea next frame; the kinetic
    # velocity cell (id.child(3)) is zeroed so a leftover glide cannot
    # fight the correction.
    private def scroll_focus_into_view(ctx : Egui::Context,
                                       memory : Egui::Memory, scroll_id : Egui::Id,
                                       viewport : Egui::Rect) : Nil
      rect = @focus_rect
      return unless rect
      offset = memory.data.get_vec2(scroll_id)
      content = memory.data.get_vec2(scroll_id.child(0))
      max_v = {content.y - viewport.height, 0.0}.max
      margin = rect.height
      top = rect.top - viewport.min.y + offset.y
      bottom = top + rect.height
      target = offset.y
      if top < offset.y + margin
        target = top - margin
      elsif bottom > offset.y + viewport.height - margin
        target = bottom + margin - viewport.height
      end
      target = target.clamp(0.0, max_v)
      return if target == offset.y
      memory.data.set_vec2(scroll_id, Egui::Vec2.new(offset.x, target))
      memory.data.set_f64(scroll_id.child(3), 0.0)
      ctx.request_repaint
    end

    # Ctrl+Minus / Ctrl+Equal zoom the tree's font (whole points only)
    # while the pointer hovers it. The override lives in Memory like
    # the expand state; it rewrites ctx.style.font_size for the walk
    # alone — the surrounding panel keeps its own size.
    private def with_zoom(ui : Egui::Ui, base : Egui::Id, &) : Nil
      ctx = ui.ctx
      id = base.child(FONT_SALT)
      ctx.memory.use_id(id) # survive end-frame pruning
      input = ctx.input
      if (pos = input.pointer_pos) && ui.max_rect.contains?(pos) &&
         input.modifiers.ctrl
        if input.consume_key(Egui::KeyCode::Minus)
          zoom_by(ctx, id, -1)
        elsif input.consume_key(Egui::KeyCode::Equal)
          zoom_by(ctx, id, 1)
        end
      end
      size = ctx.memory.data.get_f64(id, 0.0)
      return yield if size <= 0.0
      old = ctx.style.font_size
      ctx.style.font_size = size
      begin
        yield
      ensure
        ctx.style.font_size = old
      end
    end

    # One whole-point step from the current size (the panel's font
    # before the first override), clamped to FONT_MIN..FONT_MAX.
    private def zoom_by(ctx : Egui::Context, id : Egui::Id,
                        delta : Int32) : Nil
      cur = ctx.memory.data.get_f64(id, 0.0)
      base = cur > 0.0 ? cur : ctx.style.font_size
      ctx.memory.data.set_f64(id, (base + delta).round.clamp(FONT_MIN,
        FONT_MAX))
      ctx.request_repaint
    end

    # Depth-first walk of the expanded directories; every visible row
    # is laid out in order. Directories render their listing only when
    # open (lazy Dir.children through the listing cache).
    private def walk(ui : Egui::Ui, memory : Egui::Memory, base : Egui::Id,
                     path : String, depth : Int32, active : String?,
                     show_hidden : Bool, chevrons : Bool) : Nil
      dir = File.directory?(path)
      node_id = base.child(Egui::Id.from(path).value)
      open = memory.data.get_bool(node_id, depth.zero?)

      row(ui, memory, node_id, path, depth, dir, open,
        active == path, path == @last_touched, chevrons)

      if dir && open
        FileTree.listing(path).each do |e|
          next if !show_hidden && e.name.starts_with?('.')
          child = File.join(path, e.name)
          walk(ui, memory, base, child, depth + 1, active, show_hidden,
            chevrons)
        end
      end
    end

    # One row: [chevron|blank][icon] name. Click on a directory toggles
    # it; click on a file (or its row) activates it. Every click also
    # marks the row last_touched — the dim highlight sticks when the
    # row never becomes active (directories, unopenable files) and is
    # dropped by `ui` the moment it does. `chevrons: false`
    # drops the toggle arrows — the folder/folder-open icons carry the
    # open state, and the icon column starts right at the indent.
    #
    # Rows are also Sense::Focusable: click takes focus, Up/Down walk
    # the rows through egui's geometric focus navigation, and Enter on
    # the focused row acts exactly like a click (activate below).
    private def row(ui : Egui::Ui, memory : Egui::Memory,
                    node_id : Egui::Id, path : String, depth : Int32,
                    dir : Bool, open : Bool, active : Bool,
                    last_touched : Bool, chevrons : Bool) : Nil
      style = ui.style
      v = style.visuals
      line_h = {style.font_size * Egui::Fonts::LINE_H_FACTOR,
        style.spacing.interact_size.y}.max
      indent = depth * INDENT
      rect = ui.allocate_at_least(
        Egui::Vec2.new(ui.max_rect.width - indent, line_h))
      # The row spans from its indent to the region's right edge —
      # NOT `rect.width - indent`: the allocation was already shrunk
      # by the indent (and clamped by max_rect.right), so re-using it
      # would end the highlight `indent` px short of the edge, before
      # long names on deeply nested rows.
      row_rect = Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.left + indent, rect.top),
        Egui::Vec2.new(
          {ui.max_rect.right - (rect.left + indent), 0.0}.max, line_h))
      response = ui.interact(row_rect, node_id,
        Egui::Sense.click | Egui::Sense::Focusable)
      focused = response.has_focus?
      @focus_rect = row_rect if focused

      if response.clicked?
        response.request_focus
        activate(ui.ctx, memory, node_id, path, dir, open)
      end
      # Enter on the keyboard-cursor row behaves exactly like a click.
      if focused && ui.ctx.input.consume_key(Egui::KeyCode::Enter)
        activate(ui.ctx, memory, node_id, path, dir, open)
      end

      if active
        ui.painter.rect(row_rect, 3.0, v.selection_fill)
      elsif last_touched || focused
        ui.painter.rect(row_rect, 3.0, v.fade_color(v.selection_fill, 0.6))
      elsif response.hovered?
        ui.painter.rect(row_rect, 3.0, v.fade_color(v.selection_fill, 0.4))
      end

      fg = v.text_color
      x = row_rect.left

      # Toggle arrow for directories (blank slot for files) — skipped
      # entirely when chevrons are off.
      if chevrons
        if dir
          arrow = open ? "▾" : "▸"
          ui.painter.text(Egui::Pos2.new(x + 2.0, row_rect.center.y),
            arrow, style.font_size, v.fade_color(fg, 0.6),
            family: style.font_family)
        end
        x += CHEVRON_W
      end

      # Folder/file icon.
      icon : Egui::Svg = if dir
        if open
          Egui::Icon.from_file(:lucide, :folder_open, tint: fg)
        else
          Egui::Icon.from_file(:lucide, :folder, tint: fg)
        end
      else
        file_icon(File.extname(path).downcase, fg)
      end
      icon_rect = Egui::Rect.from_min_size(
        Egui::Pos2.new(x, row_rect.center.y - ICON_SIZE / 2.0),
        Egui::Vec2.new(ICON_SIZE, ICON_SIZE))
      icon.paint(ui, icon_rect)
      x += ICON_SIZE + 4.0

      ui.painter.text(Egui::Pos2.new(x, row_rect.center.y),
        File.basename(path), style.font_size, fg, family: style.font_family)
    end

    # The click/Enter action in one place: touch the row (the dim
    # highlight), toggle a directory open/closed, or hand a file to
    # the app's on_activate block.
    private def activate(ctx : Egui::Context, memory : Egui::Memory,
                         node_id : Egui::Id, path : String,
                         dir : Bool, open : Bool) : Nil
      touch(memory, path)
      if dir
        memory.data.set_bool(node_id, !open)
      elsif (cb = @on_activate)
        cb.call(path)
      end
      ctx.request_repaint
    end

    # Record the click in Memory#data (and this frame's ivar) so the
    # dim highlight survives until the row becomes active or another
    # row is touched.
    private def touch(memory : Egui::Memory, path : String) : Nil
      if (id = @last_touched_id)
        memory.data.set_string(id, path)
      end
      @last_touched = path
    end

    private def file_icon(ext : String, fg : Egui::Color32) : Egui::Svg
      case EXT_ICONS[ext]?
      when :file_code     then Egui::Icon.from_file(:lucide, :file_code, tint: fg)
      when :file_terminal then Egui::Icon.from_file(:lucide, :file_terminal, tint: fg)
      when :braces        then Egui::Icon.from_file(:lucide, :braces, tint: fg)
      when :file_text     then Egui::Icon.from_file(:lucide, :file_text, tint: fg)
      when :file_image    then Egui::Icon.from_file(:lucide, :file_image, tint: fg)
      when :file_archive  then Egui::Icon.from_file(:lucide, :file_archive, tint: fg)
      else                     Egui::Icon.from_file(:lucide, :file, tint: fg)
      end
    end

    @on_activate : (String ->)?
    @last_touched_id : Egui::Id?
    @last_touched : String = ""
    # This frame's focused-row rect (screen coords), for scroll-into-view.
    @focus_rect : Egui::Rect?
  end
end

class Egui::Ui
  # kodkod's file explorer. `root` is an absolute directory path; the
  # block receives the absolute path of every file row the user
  # clicks (or Enters — see below). Directories toggle expand/collapse
  # on click. `active:` is the open file's path (full selection fill);
  # every clicked row that does not become active (a toggled
  # directory, a file the app declined to open) keeps a dimmer
  # last_touched highlight instead. `chevrons:` (default true) draws
  # the ▸/▾ toggle arrows; false leaves the open/closed state to the
  # folder icons alone.
  #
  # The widget brings its own scroll area. Rows are keyboard-navigable:
  # click (or Tab) focuses a row, Up/Down walk the visible rows, Enter
  # toggles a folder or opens a file, and the focused row is scrolled
  # into view automatically.
  def file_tree(id : String, root : String, active : String? = nil,
                show_hidden : Bool = false, chevrons : Bool = true,
                &on_activate : String ->) : Nil
    Kodkod::FileTree.new(id).ui(self, root, active, show_hidden,
      chevrons, &on_activate)
  end
end
