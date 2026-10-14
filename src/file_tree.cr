# kodkod — FileTree: a lazy-loading file explorer widget.
#
# TreeView builds its rows from an app-supplied block every frame; a
# directory tree wants the opposite — rows COME from the filesystem,
# read only when a node is first expanded (a repo with 10k files must
# not stat anything until asked). Directory listings are cached per
# path. Refresh is event-driven where the platform offers it (Linux:
# inotify — see `watch`; an external touch shows up next frame) with
# the RECHECK mtime poll as the backstop, and poll-only elsewhere.
# F5/`refresh` drops everything wholesale.
#
# Expand state lives in Memory#data keyed by the entry's absolute path
# id — surviving frames like TreeView, no app-held state. Rows carry
# two highlight states: `active` (the app-supplied open file, full
# selection fill) and `last_touched` — the last clicked row that did
# NOT become active (a toggled directory, a file the app declined to
# open), painted as a dimmer fill. Every click records the touch in
# Memory#data; once the touched row graduates to `active`, the touch
# is forgotten. When `active` CHANGES between frames the tree reveals
# it reactively: the ancestor directories are expanded and the row is
# scrolled into view (see `ui`). Icons are
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

{% if flag?(:linux) %}
  # Linux: listing invalidation rides on real filesystem events. The
  # libc wrappers (glibc/musl both ship them) are enough — no shard,
  # no C shim. See FileTree.watch below.
  @[Link("c")]
  lib LibInotify
    fun init1 = inotify_init1(flags : Int32) : Int32
    fun add_watch = inotify_add_watch(fd : Int32, pathname : UInt8*,
                                      mask : UInt32) : Int32
    fun rm_watch = inotify_rm_watch(fd : Int32, wd : Int32) : Int32
  end
{% end %}

module Kodkod
  class FileTree
    record Entry, name : String, dir : Bool

    class Listing
      property mtime : Time?
      property entries : Array(Entry)
      # When the directory was last re-statted — throttles the
      # recheck (see RECHECK): the walk runs every frame and a stat
      # per expanded directory per frame is the same syscall storm
      # the per-row File.directory? used to cause.
      property checked_at : Time::Instant

      def initialize(@mtime : Time?, @entries : Array(Entry))
        @checked_at = Time.instant
      end
    end

    # path => listing; bounded by the number of directories ever
    # expanded this session. Keyed by the REAL expanded path — the
    # hidden-file filter is applied at render, so toggling it back and
    # forth never re-stats.
    @@listings = {} of String => Listing

    # How long a cached listing is trusted before its directory is
    # re-statted. On platforms WITH filesystem events this is only the
    # BACKSTOP (watch-table limits, event-queue overflow); elsewhere
    # it is the refresh interval proper. Either way the tree renders
    # every frame, so without the throttle each expanded directory
    # would cost one stat per frame.
    RECHECK = 0.5.seconds

    def self.refresh : Nil
      @@listings.clear
      drop_watches
    end

    def self.listing(dir : String) : Array(Entry)
      if (cached = @@listings[dir]?)
        if Time.instant - cached.checked_at < RECHECK
          return cached.entries
        end
        cached.checked_at = Time.instant
        mtime = File.info?(dir).try(&.modification_time)
        return cached.entries if cached.mtime == mtime
      end
      mtime = File.info?(dir).try(&.modification_time)
      entries = Dir.children(dir).reject { |n| n == ".git" }.map do |n|
        Entry.new(n, File.directory?(File.join(dir, n)))
      end.sort_by! do |e|
        {e.dir ? 0 : 1, e.name.downcase}
      end
      @@listings[dir] = Listing.new(mtime, entries)
      watch(dir)
      entries
    end

    # --- filesystem events -----------------------------------------
    #
    # Linux delivers directory changes through inotify: every
    # directory that gets a cached listing is watched, and the reader
    # fiber below drops the cached entry the moment the kernel
    # reports a change — the next frame's walk re-lists it, so an
    # external touch (git checkout, mkdir, another editor) shows up
    # immediately, not at the next RECHECK poll. The delivery is the
    # PTY-reader pattern (backend/pty.cr): the fd goes through an
    # EVENTED IO::FileDescriptor (epoll), the fiber suspends in read
    # instead of blocking its worker thread, and the on_change
    # doorbell (Context#request_repaint → Runtime.wake, installed by
    # `ui`) wakes the detached render loop between frames.
    #
    # Other platforms keep the RECHECK poll — FSEvents (macOS) or
    # ReadDirectoryChangesW (Windows) can slot into the same
    # watch/drop_watches pair later.
    {% if flag?(:linux) %}
      # Only the masks used here. WATCH_MASK omits IN_MODIFY and
      # IN_ATTRIB on purpose: a file's content/metadata never changes
      # its directory's LISTING (only create/delete/move do, and each
      # of those bumps the directory mtime anyway).
      IN_CREATE      = 0x100_u32
      IN_MOVED_FROM  =  0x40_u32
      IN_MOVED_TO    =  0x80_u32
      IN_DELETE      = 0x200_u32
      IN_DELETE_SELF = 0x400_u32
      IN_MOVE_SELF   = 0x800_u32
      IN_Q_OVERFLOW  = 0x4000_u32
      IN_IGNORED     = 0x8000_u32
      WATCH_MASK = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO |
                   IN_DELETE_SELF | IN_MOVE_SELF
      IN_NONBLOCK = 0o4000
      IN_CLOEXEC  = 0o2000000

      @@watch_fd = -1
      @@watch_io : IO::FileDescriptor? = nil
      @@wd_paths = {} of Int32 => String
      @@path_wds = {} of String => Int32
      # Repaint doorbell, re-installed by `ui` every frame.
      @@on_change : Proc(Nil)? = nil

      def self.on_change=(cb : Proc(Nil)) : Nil
        @@on_change = cb
      end

      # Idempotent watch registration for an expanded directory.
      # Silent on failure (permissions, watch-table full) — the
      # RECHECK poll stays the backstop. A renamed ANCESTOR leaves a
      # stale wd→path entry behind until the next refresh; harmless
      # (it can only invalidate a path nothing reads) and bounded by
      # the number of directories ever expanded.
      def self.watch(path : String) : Nil
        return if @@path_wds.has_key?(path)
        if @@watch_fd < 0
          fd = LibInotify.init1(IN_NONBLOCK | IN_CLOEXEC)
          return if fd < 0
          @@watch_fd = fd
          io = IO::FileDescriptor.new(fd)
          # The constructor's type probe doesn't know inotify fds (an
          # anon inode is neither pipe nor socket) so it assumes
          # blocking — and CLEARS the fd's O_NONBLOCK, which would
          # wedge the whole scheduler thread in read. Re-arm it: the
          # evented read then suspends the fiber on EAGAIN (epoll),
          # the PTY-reader pattern.
          IO::FileDescriptor.set_blocking(fd, false)
          @@watch_io = io
          spawn reader_loop(io), name: "kodkod-fs-watch"
          # Let the reader reach its first (evented, suspending) read
          # before this frame goes on — the PTY spawn trick.
          Fiber.yield
        end
        wd = LibInotify.add_watch(@@watch_fd, path, WATCH_MASK)
        return if wd < 0
        @@wd_paths[wd] = path
        @@path_wds[path] = wd
      end

      # F5/refresh: the listings come back through `listing` (which
      # re-registers watches); IN_IGNORED events for the removed
      # watches are no-ops (the maps are already empty).
      def self.drop_watches : Nil
        @@path_wds.each_value { |wd| LibInotify.rm_watch(@@watch_fd, wd) }
        @@wd_paths.clear
        @@path_wds.clear
      end

      # Decode inotify_event records off the fd until it dies. Runs
      # OUTSIDE the frame fiber: cache drops are safe because the
      # scheduler is cooperative (no yield inside Hash#delete) and
      # the walk only ever holds the entries Array, never the Hash.
      private def self.reader_loop(io : IO::FileDescriptor) : Nil
        header = Bytes.new(16)
        loop do
          break unless io.read_fully?(header)
          wd = IO::ByteFormat::SystemEndian.decode(Int32, header[0, 4])
          mask = IO::ByteFormat::SystemEndian.decode(UInt32, header[4, 4])
          len = IO::ByteFormat::SystemEndian.decode(UInt32,
            header[12, 4]).to_i
          break unless io.read_fully?(Bytes.new(len)) # name slot, unread
          if mask & IN_Q_OVERFLOW != 0
            @@listings.clear # kernel dropped events — reload the world
            @@on_change.try &.call
          end
          next unless (path = @@wd_paths[wd]?)
          if mask & IN_IGNORED != 0
            @@path_wds.delete(path) # watch removed (rm_watch / dir gone)
            @@wd_paths.delete(wd)
          elsif (mask & WATCH_MASK) != 0 && @@listings.delete(path)
            @@on_change.try &.call # wake the loop for a fresh walk
          end
        end
      rescue ex : IO::Error
        # fd closed or unreadable — the RECHECK poll takes over.
      ensure
        @@watch_fd = -1
        @@watch_io = nil
        @@wd_paths.clear
        @@path_wds.clear
      end
    {% else %}
      # No filesystem events on this platform (yet): the RECHECK poll
      # is the refresh path.
      def self.watch(path : String) : Nil
      end

      def self.drop_watches : Nil
      end

      def self.on_change=(cb : Proc(Nil)) : Nil
      end
    {% end %}

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
    # Vertical padding INSIDE a row. Rows stack flush (item_spacing.y
    # is zeroed for the walk, see `ui`), so the breathing room between
    # entries comes from here — the highlight bands stay contiguous.
    ROW_PAD = 3.0
    FONT_SALT = 0xF017_u64 # Ctrl +/- font zoom override
    FONT_MIN = 8.0
    FONT_MAX = 40.0

    def initialize(@id : String)
    end

    def ui(ui : Egui::Ui, root : String, active : String? = nil,
           show_hidden : Bool = false, chevrons : Bool = true,
           &on_activate : String ->) : Nil
      memory = ui.ctx.memory
      # The fs-event doorbell, re-anchored every frame: inotify
      # invalidations land BETWEEN frames (reader fiber — see watch),
      # where request_repaint must also wake the backend loop
      # (Egui::Runtime.wake) or the fresh listing would wait for the
      # next unrelated repaint.
      FileTree.on_change = ->{ ui.ctx.request_repaint }
      base = Egui::Id.from("kodkod/file_tree/#{@id}")
      @on_activate = on_activate
      @last_touched_id = lt_id = base.child(Egui::Id.from("last_touched").value)
      memory.use_id(lt_id) # survive end-frame pruning
      @last_touched = memory.data.get_string(lt_id)
      if active && @last_touched == active
        @last_touched = ""
        memory.data.set_string(lt_id, "")
      end
      # Reactive reveal: when the app-supplied `active` path CHANGES
      # between frames (a tab switch, a fresh open), the tree follows
      # the editor — expand the ancestor chain below so the walk
      # renders the row this frame, then scroll it into view. Paths
      # outside `root` expand nothing (the highlight matches no row).
      active_id = base.child(Egui::Id.from("last_active").value)
      memory.use_id(active_id) # survive end-frame pruning
      @reveal = false
      if (path = active) && path != memory.data.get_string(active_id)
        @reveal = true
        expand_to(memory, base, root, path)
      end
      memory.data.set_string(active_id, active || "")
      # The tree scrolls in its OWN area (a stable id under `base`) so
      # the focused row's rect, recorded during the walk, can be
      # brought into view afterwards (see scroll_focus_into_view).
      # Reset before the walk: this frame's focus target, if any.
      @focus_rect = nil
      @focus_path = nil
      @active_rect = nil
      scroll_id = base.child(Egui::Id.from("scroll").value)
      viewport = Egui::ScrollArea.new(id: scroll_id).show(ui) do |inner|
        # Flush rows: zero the layout's item_spacing.y for the walk so
        # rows stack with NO gap between their highlight bands — the
        # spacing moves into the rows themselves (ROW_PAD in `row`),
        # like a native file explorer list.
        old_is = inner.style.spacing.item_spacing
        inner.style.spacing.item_spacing = Egui::Vec2.new(old_is.x, 0.0)
        begin
          with_zoom(inner, base) do
            # The root's dir-ness is the ONE stat the tree pays per
            # frame (the workspace folder may vanish out from under
            # the app); every row below carries its Entry's flag.
            walk(inner, memory, base, root, File.directory?(root), 0,
              active, show_hidden, chevrons)
          end
        ensure
          inner.style.spacing.item_spacing = old_is
        end
      end
      # Follow the keyboard cursor ONLY when focus moves to a row:
      # while it merely STAYS on a row (e.g. after the click that
      # opened the file) the user's own scrolling is left alone —
      # re-clamping every frame would pin the viewport to that row.
      focus_cell = base.child(Egui::Id.from("last_focus").value)
      memory.use_id(focus_cell) # survive end-frame pruning
      if (rect = @focus_rect) && (path = @focus_path) &&
         path != memory.data.get_string(focus_cell)
        scroll_rect_into_view(ui.ctx, memory, scroll_id, viewport, rect)
      end
      memory.data.set_string(focus_cell, @focus_path || "")
      if @reveal && (rect = @active_rect)
        scroll_rect_into_view(ui.ctx, memory, scroll_id, viewport, rect)
      end
    end

    # Keep a row inside the viewport after arrow navigation or a
    # reveal: the walk recorded its rect (screen coords); shifted into
    # content space it must land in [offset.y, offset.y +
    # viewport.height], with one row of context kept above/below.
    # Writing the offset cell directly is picked up by the ScrollArea
    # next frame; the kinetic velocity cell (id.child(3)) is zeroed so
    # a leftover glide cannot fight the correction.
    private def scroll_rect_into_view(ctx : Egui::Context,
                                      memory : Egui::Memory, scroll_id : Egui::Id,
                                      viewport : Egui::Rect,
                                      rect : Egui::Rect) : Nil
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

    # Open the root→path directory chain so the upcoming walk renders
    # the active file's row this frame. Paths outside `root` expand
    # nothing — the highlight simply matches no row.
    private def expand_to(memory : Egui::Memory, base : Egui::Id,
                          root : String, path : String) : Nil
      prefix = root.ends_with?('/') ? root : root + '/'
      return unless path.starts_with?(prefix)
      dir = File.dirname(path)
      while dir != "/" && dir != root
        memory.data.set_bool(base.child(Egui::Id.from(dir).value), true)
        dir = File.dirname(dir)
      end
      memory.data.set_bool(base.child(Egui::Id.from(root).value), true)
    end

    # Depth-first walk of the expanded directories; every visible row
    # is laid out in order. `dir` comes from the PARENT's cached
    # listing (the Entry flag) — never a per-row stat: this walk runs
    # every frame, and File.directory? here used to cost one syscall
    # per visible row. Directories render their listing only when
    # open (lazy Dir.children through the listing cache).
    private def walk(ui : Egui::Ui, memory : Egui::Memory, base : Egui::Id,
                     path : String, dir : Bool, depth : Int32, active : String?,
                     show_hidden : Bool, chevrons : Bool) : Nil
      node_id = base.child(Egui::Id.from(path).value)
      open = memory.data.get_bool(node_id, depth.zero?)

      row(ui, memory, node_id, path, depth, dir, open,
        active == path, path == @last_touched, chevrons)

      if dir && open
        FileTree.listing(path).each do |e|
          next if !show_hidden && e.name.starts_with?('.')
          child = File.join(path, e.name)
          walk(ui, memory, base, child, e.dir, depth + 1, active, show_hidden,
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
        style.spacing.interact_size.y}.max + 2.0 * ROW_PAD
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
      @focus_path = path if focused
      @active_rect = row_rect if active

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
    # This frame's focused-row rect (screen coords) and path, for
    # scroll-into-view on focus CHANGE (not every frame — see `ui`).
    @focus_rect : Egui::Rect?
    @focus_path : String?
    # This frame's active-row rect, for the reveal scroll; @reveal says
    # `active` changed since the previous frame.
    @active_rect : Egui::Rect?
    @reveal = false
  end
end

class Egui::Ui
  # kodkod's file explorer. `root` is an absolute directory path; the
  # block receives the absolute path of every file row the user
  # clicks (or Enters — see below). Directories toggle expand/collapse
  # on click. `active:` is the open file's path (full selection fill);
  # every clicked row that does not become active (a toggled
  # directory, a file the app declined to open) keeps a dimmer
  # last_touched highlight instead. When `active:` changes from the
  # previous frame the tree REVEALS the file: its ancestor directories
  # are expanded and the row is scrolled into view — pass it as a
  # function of your tab bar and the explorer follows the editor with
  # no extra wiring. `chevrons:` (default true) draws the ▸/▾ toggle
  # arrows; false leaves the open/closed state to the
  # folder icons alone.
  #
  # The widget brings its own scroll area. Rows are keyboard-navigable:
  # click (or Tab) focuses a row, Up/Down walk the visible rows, Enter
  # toggles a folder or opens a file, and a row focus MOVES to is
  # scrolled into view automatically (a row merely KEEPING focus never
  # fights the user's own scrolling).
  def file_tree(id : String, root : String, active : String? = nil,
                show_hidden : Bool = false, chevrons : Bool = true,
                &on_activate : String ->) : Nil
    Kodkod::FileTree.new(id).ui(self, root, active, show_hidden,
      chevrons, &on_activate)
  end
end
