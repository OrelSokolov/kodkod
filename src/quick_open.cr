# kodkod — the Sublime-style fuzzy file finder (Ctrl+P): a floating
# panel at the top of the window with a query field over a live
# fuzzy-filtered list of the workspace files. Ranking is RubyMine-like:
# matches in the file NAME outrank matches confined to the path, and
# the name is scored on its own (prefix first, then word boundaries,
# then scattered). Up/Down walk the list, Enter opens, Esc or a click
# outside closes.
#
# The panel is a framework `ctx.popup`: riding the Foreground layer,
# closed automatically on an outside click. The query field would
# swallow Up/Down (single-line Home/End) and Escape when focused, so
# the list's key handling runs BEFORE the field renders and claims the
# keys first (`InputState#consume_key` is first-come-first-served).
#
# Filtering is CACHED: it re-runs only when the query (or the file
# list) changes, never per frame — the DP scorer over thousands of
# paths is far too slow to pay 60×/s, and even once per keystroke it
# only runs on files that pass the cheap subsequence gate.

require "egui-cr/egui"
require "./fuzzy"

module Kodkod
  class QuickOpen
    POPUP_ID = "quickopen"
    WIDTH    = 600.0
    # Rows shown at once — the list is pre-truncated, no scroll needed.
    MAX_ROWS = 12
    # At most this many gate survivors get scored per keystroke: a
    # broad query ("s" over a vendored tree) matches everything, and
    # ranking 20k paths in one go would hitch; the cap lifts on its own
    # as soon as the query narrows below it. The first survivors win —
    # the list is alphabetical, so the cut is deterministic.
    SCORE_CAP = 2000
    # The recursive walk stops here — huge trees open instantly, just
    # incompletely (the cap beats a frozen UI on Ctrl+P).
    MAX_FILES = 20_000
    # Symlink cycles die at this depth instead of looping forever.
    MAX_DEPTH = 24

    property query = ""
    # The query field's hint — the app keeps it in the UI language.
    property hint = "Go to file…"
    @selected = 0
    @files = [] of String    # Lowercased twins of @files — the per-keystroke gate and the DP
    # compare case-insensitively; re-lowercasing 20k paths every
    # keystroke is pure garbage-churn.
    @files_lc = [] of String
    # Byte offset of each file's name within its path and its length
    # (tier-0 scoring runs over the name suffix; the offsets keep it
    # allocation-free, the lengths break score ties — shorter name,
    # higher rank, like RubyMine).
    @name_off = [] of Int32
    @name_len = [] of Int32
    @focus_pending = false
    @was_open = false
    # The cached visible rows + the query/files they were computed for
    # (nil = stale, recompute on the next #show) and the FULL match
    # count for the footer (rows are capped, the count is not).
    @rows : Array({String, Fuzzy::Result?}) = [] of {String, Fuzzy::Result?}
    @rows_query : String? = nil
    @match_count = 0
    # The last query's surviving candidate indexes (`@cand` for
    # `@cand_query`): extending the query only ever DROPS candidates
    # (subsequence match is monotone), so each keystroke gates the
    # previous survivors instead of the whole file list.
    @cand : Array(Int32) = [] of Int32
    @cand_query : String? = nil
    @scorer = Scorer.new(1)
    # Fired when the panel closed (however it closed) so the app can
    # hand focus back to the active editor.
    property on_close : (-> Nil)? = nil

    def open?(ctx : Egui::Context) : Bool
      ctx.popup_open?(POPUP_ID)
    end

    def open(ctx : Egui::Context, folder : String, show_hidden : Bool) : Nil
      self.files = self.class.files_under(folder, show_hidden)
      @query = ""
      @selected = 0
      @focus_pending = true
      ctx.open_popup(POPUP_ID)
    end

    # The searchable list (workspace-relative paths), its lowercase
    # twin and per-file name offsets; the row caches drop so the next
    # #rows recomputes, and the scorer's reusable buffers resize to the
    # longest path.
    def files=(files : Array(String))
      @files = files
      @files_lc = files.map(&.downcase)
      @name_off = files.map { |f| self.class.name_offset(f) }
      @name_len = files.map_with_index { |f, i| f.bytesize - @name_off[i] }
      @scorer = Scorer.new(files.empty? ? 1 : files.max_of(&.size))
      @rows_query = nil
      @cand_query = nil
    end

    def close(ctx : Egui::Context) : Nil
      ctx.close_popup(POPUP_ID)
      ctx.memory.focus.clear
    end

    # Renders the panel (a no-op while closed) and drives its keyboard;
    # *on_pick* receives the chosen workspace-relative path.
    def show(ctx : Egui::Context, &on_pick : String ->) : Nil
      open = open?(ctx)
      if @was_open && !open && (cb = @on_close)
        cb.call
      end
      @was_open = open
      return unless open

      rows = self.rows
      @selected = @selected.clamp(0, {rows.size - 1, 0}.max)

      # Keyboard FIRST — see the class comment. Enter is never taken by
      # the single-line field, but claiming it here keeps one code path.
      if ctx.input.consume_key(Egui::KeyCode::Escape)
        close(ctx)
        return
      elsif ctx.input.consume_key(Egui::KeyCode::Up)
        @selected -= 1 if @selected > 0
        ctx.request_repaint
      elsif ctx.input.consume_key(Egui::KeyCode::Down)
        @selected += 1 if @selected < rows.size - 1
        ctx.request_repaint
      elsif ctx.input.consume_key(Egui::KeyCode::Enter)
        if (row = rows[@selected]?)
          close(ctx)
          on_pick.call(row[0])
        end
        return
      end

      screen = ctx.input.screen_rect
      anchor = Egui::Pos2.new(screen.center.x - WIDTH / 2.0, screen.top + 48.0)
      ctx.popup(POPUP_ID, anchor, width: WIDTH) do |ui|
        # Sublime's query line: flat, frameless, the panel's full width
        # — not a boxed form field. `add_sized` stretches the edit
        # across the panel (its natural size is just the typed text);
        # the on_change callback of #text_edit_singleline is inlined
        # here (Response#widget_text carries the new buffer).
        field = Egui::TextEdit.new(@query, @hint, false,
          "kodkod-quickopen", false)
        # The cell must cover the edit's NATURAL height (line height
        # over its vertical inset — button padding + the 2px border
        # reserve, see TextEdit#ui). #add_sized is a hard bound: a
        # shorter cell clamps the field and its content clip cuts the
        # typed text mid-glyph, so the query line reads as one
        # squeezed strip under the result rows.
        line_h = {ui.ctx.fonts_for(ui.style.font_family)
                    .measure("Ag", ui.style.font_size).y,
                  ui.style.spacing.interact_size.y}.max
        field_h = line_h + 2.0 * (ui.style.spacing.button_padding.y + 2.0)
        resp = ui.add_sized(Egui::Vec2.new(ui.available_width, field_h), field)
        if resp.changed? && (text = resp.widget_text)
          @query = text
          @selected = 0
        end
        if @focus_pending
          resp.request_focus
          @focus_pending = false
        end
        rows.each_with_index do |(path, result), i|
          if row(ui, path, result, selected: i == @selected).clicked?
            close(ctx)
            on_pick.call(path)
          end
        end
        footer(ui, rows)
      end
    end

    # --- the cached rows -------------------------------------------------

    # The rows for the current query (recomputed only when the query or
    # the file list changed since the last call).
    def rows : Array({String, Fuzzy::Result?})
      if @rows_query != @query
        if @query.empty?
          @match_count = @files.size
          @rows = @files.first(MAX_ROWS)
                         .map { |path| {path, nil.as(Fuzzy::Result?)} }
          @cand_query = nil # the candidate cache is void for ""
        else
          @rows = filter_files
        end
        @rows_query = @query
      end
      @rows
    end

    # The cached rows' source: an allocation-free subsequence gate over
    # the pre-lowercased paths, then two-tier scoring (RubyMine-style)
    # on the candidates through a buffer-reusing Scorer (capped — see
    # SCORE_CAP):
    #
    #   tier 0 — the query matches the file NAME (scored over the name
    #   alone: a name prefix beats a name middle, regardless of how
    #   deep the file sits);
    #   tier 1 — only the path matches (scored over the full path,
    #   the old behavior).
    #
    # Tier 0 always outranks tier 1; within a tier, score desc, then
    # the shorter file name first (equal-quality matches in long
    # vendored names must not crowd out `src/app.cr`), then input
    # order. Only the top rows pay for Fuzzy.match — the positions it
    # returns are just for highlighting.
    #
    # When the new query EXTENDS the cached one the gate runs over the
    # previous survivors only — a longer query cannot admit a path the
    # shorter one rejected.
    private def filter_files : Array({String, Fuzzy::Result?})
      dquery = @query.downcase
      size = dquery.bytesize
      gate = [] of Int32
      prev_query = @cand_query
      if prev_query && prev_query.bytesize < size &&
         dquery.starts_with?(prev_query)
        source = @cand
        source.each do |idx|
          gate << idx if subsequence?(dquery, size, @files_lc[idx])
        end
      else
        @files_lc.each_with_index do |lc, idx|
          gate << idx if subsequence?(dquery, size, lc)
        end
      end
      @cand = gate
      @cand_query = dquery

      scored = [] of {Int32, Int32, Int32, Int32} # {index, tier, score, len}
      gate.first(SCORE_CAP).each do |idx|
        off = @name_off[idx]
        if s = @scorer.score(dquery, @files_lc[idx], @files[idx], from: off)
          scored << {idx, 0, s, @name_len[idx]}
        elsif s = @scorer.score(dquery, @files_lc[idx], @files[idx])
          scored << {idx, 1, s, @name_len[idx]}
        end
      end
      scored.sort_by! { |idx, tier, s, len| {tier, -s, len, idx} }
      @match_count = gate.size
      scored.first(MAX_ROWS).map do |idx, tier, _s|
        {@files[idx],
         self.class.match_result(@files[idx], @query, tier).as(Fuzzy::Result?)}
      end
    end

    # The subsequence gate on pre-lowercased text — raw byte comparison
    # (paths are ASCII), bailing the moment the query is spent.
    private def subsequence?(dquery : String, size : Int32, lc : String) : Bool
      dqp = dquery.to_unsafe
      lcp = lc.to_unsafe
      qi = 0
      i = 0
      n = lc.bytesize
      while i < n
        if lcp[i] == dqp[qi]
          qi += 1
          return true if qi >= size
        end
        i += 1
      end
      false
    end

    # Byte offset of the file name within a workspace-relative path
    # (0 for root files). Paths are ASCII, so byte == char offset.
    def self.name_offset(path : String) : Int32
      path.bytesize - File.basename(path).bytesize
    end

    # The visible rows for *query* (uncached, for callers/tests): with
    # an empty query the files in their natural (sorted) order,
    # otherwise RubyMine-style — files whose NAME matches the query
    # first (score desc over the name alone, shorter names on ties),
    # then path-only matches (score desc over the full path), stable
    # on ties.
    def self.rank(files : Array(String), query : String,
                  limit : Int32 = MAX_ROWS) : Array({String, Fuzzy::Result?})
      if query.empty?
        files.first(limit).map { |path| {path, nil.as(Fuzzy::Result?)} }
      else
        # The two-tier ranking `#filter_files` documents in detail:
        # tier 0 = the query matches the file name, tier 1 = only the
        # path. This uncached twin uses Fuzzy.match directly (the
        # Scorer's scores are pinned equal to it by spec, so the
        # orderings agree).
        scored = [] of {Int32, Int32, Int32, Int32} # {index, tier, score, len}
        files.each_with_index do |path, idx|
          next unless Fuzzy.matches?(query, path)
          off = name_offset(path)
          if r = Fuzzy.match(query, path.byte_slice(off))
            scored << {idx, 0, r.score, path.bytesize - off}
          elsif r = Fuzzy.match(query, path)
            scored << {idx, 1, r.score, path.bytesize - off}
          end
        end
        scored.sort_by! { |idx, tier, s, len| {tier, -s, len, idx} }
        scored.first(limit).map do |idx, tier, _s, _len|
          {files[idx], match_result(files[idx], query, tier).as(Fuzzy::Result?)}
        end
      end
    end

    # The highlight result for a ranked row: tier 0 matched the name —
    # positions are recomputed over the name and shifted so the row
    # renderer (which indexes into the full path) keeps one code path.
    def self.match_result(path : String, query : String,
                          tier : Int32) : Fuzzy::Result?
      if tier == 0
        off = name_offset(path)
        Fuzzy.match(query, path.byte_slice(off)).try do |r|
          Fuzzy::Result.new(r.score, r.positions.map(&.+ off))
        end
      else
        Fuzzy.match(query, path)
      end
    end

    # --- the file walk ---------------------------------------------------

    # Every workspace file as a sorted list of folder-relative paths.
    # Hidden entries (and `.git`, always) are skipped unless asked; a
    # depth cap breaks symlink cycles, a size cap bounds the walk.
    def self.files_under(folder : String, show_hidden : Bool) : Array(String)
      files = [] of String
      walk(folder, "", show_hidden, files, 0)
      files.sort!
    end

    private def self.walk(dir : String, rel : String, show_hidden : Bool,
                          acc : Array(String), depth : Int32) : Nil
      return if depth >= MAX_DEPTH || acc.size >= MAX_FILES
      Dir.each_child(dir) do |name|
        next if name == ".git"
        next if !show_hidden && name.starts_with?('.')
        path = File.join(dir, name)
        relname = rel.empty? ? name : "#{rel}/#{name}"
        # Symlinks are skipped, not followed: shards' lib/ symlinks
        # point back into the workspace, and following them duplicated
        # whole subtrees until the caps cut the walk off — Ctrl+P then
        # listed vendored noise instead of src/.
        next if File.symlink?(path)
        if File.directory?(path)
          walk(path, relname, show_hidden, acc, depth + 1)
        else
          acc << relname
        end
        return if acc.size >= MAX_FILES
      end
    rescue File::Error | IO::Error
      # An unreadable subtree is skipped, not fatal.
    end

    # --- row rendering ---------------------------------------------------

    # One result row: full-width, hover/selected fill, the file name
    # with fuzzy-matched characters accented and the folder dimmed —
    # Sublime's Goto Anything look. Painted by hand (segment × segment
    # through the painter) because labels can't color spans.
    private def row(ui : Egui::Ui, path : String, result : Fuzzy::Result?,
                    selected : Bool) : Egui::Response
      style = ui.style
      visuals = style.visuals
      fonts, face_family, face_bold = ui.ctx.fonts_for_weight(
        style.font_family, nil, false)
      fs = style.font_size
      pad = style.spacing.button_padding
      painter = ui.painter

      name = File.basename(path)
      dir = File.dirname(path)
      has_dir = dir != "."
      positions = result.try(&.positions) || [] of Int32
      # Matched positions are indexes into the REL path; the name is
      # its suffix, the dir its prefix.
      base_off = path.size - name.size
      name_hits = positions.select { |p| p >= base_off }.map(&.- base_off)
      dir_hits = has_dir ? positions.select { |p| p < dir.size } : [] of Int32

      sep = "  ·  "
      natural = fonts.measure(name, fs).x +
                (has_dir ? fonts.measure(sep + dir, fs).x : 0.0)
      height = {fonts.measure(name, fs).y + 2 * pad.y,
                 style.spacing.interact_size.y}.max
      rect = ui.allocate_at_least(Egui::Vec2.new(
        {ui.available_width, natural + 2 * pad.x}.max, height))
      resp = ui.interact(rect, ui.next_widget_id, Egui::Sense.click)

      if selected
        painter.rect(rect, 4.0,
          resp.active? ? visuals.button_active
                       : visuals.fade_color(visuals.selection_fill, 0.6))
      elsif resp.hovered?
        painter.rect(rect, 4.0,
          visuals.fade_color(visuals.selection_fill, 0.4))
      end

      dim = visuals.fade_color(visuals.text_color, 0.55)
      x = rect.left + pad.x
      if natural > rect.width - 2 * pad.x
        # Too long for the panel: truncate plain (no highlight) like
        # SelectableLabel's Fonts#fit fallback.
        label = has_dir ? "#{name}#{sep}#{dir}" : name
        painter.text(Egui::Pos2.new(x, rect.center.y),
          fonts.fit(label, fs, {rect.width - 2 * pad.x, 0.0}.max), fs,
          visuals.text_color, family: face_family, bold: face_bold)
      else
        x = paint_segments(painter, fonts, x, rect.center.y, name,
          name_hits, visuals.text_color, visuals.hyperlink_color,
          fs, face_family, face_bold)
        if has_dir
          painter.text(Egui::Pos2.new(x, rect.center.y), sep, fs, dim,
            family: face_family, bold: face_bold)
          x += fonts.measure(sep, fs).x
          paint_segments(painter, fonts, x, rect.center.y, dir, dir_hits,
            dim, visuals.hyperlink_color, fs, face_family, face_bold)
        end
      end
      resp
    end

    # Draws *text* at *x* as same-color runs, the characters at *hits*
    # (char indexes) in *accent* — returns the x past the last segment.
    private def paint_segments(painter : Egui::Painter, fonts : Egui::Fonts,
                               x : Float64, y : Float64, text : String,
                               hits : Array(Int32), base : Egui::Color32,
                               accent : Egui::Color32, fs : Float64,
                               family : String?, bold : Bool) : Float64
      segments(text, hits).each do |seg, accenting|
        unless seg.empty?
          painter.text(Egui::Pos2.new(x, y), seg, fs,
            accenting ? accent : base, family: family, bold: bold)
        end
        x += fonts.measure(seg, fs).x
      end
      x
    end

    # Splits *text* into (segment, accented?) runs at the *hits* char
    # indexes — adjacent same-flag characters share a run.
    private def segments(text : String, hits : Array(Int32)) : Array({String, Bool})
      segs = [] of {String, Bool}
      buf = ""
      accenting = false
      text.each_char_with_index do |c, i|
        hit = hits.includes?(i)
        if hit != accenting && !buf.empty?
          segs << {buf, accenting}
          buf = ""
        end
        accenting = hit
        buf += c
      end
      segs << {buf, accenting} unless buf.empty?
      segs
    end

    # The bottom hint line: match count + the key legend, dimmed.
    private def footer(ui : Egui::Ui, rows : Array({String, Fuzzy::Result?})) : Nil
      visuals = ui.style.visuals
      count = @query.empty? ? "#{@match_count} files" : "#{@match_count} matches"
      more = @match_count > rows.size ? "+" : ""
      hint = "#{count}#{more}   ↑↓ select · Enter open · Esc close"
      text = Egui::RichText.new(hint)
        .color(visuals.fade_color(visuals.text_color, 0.55))
        .size(ui.style.font_size * 0.85)
      ui.rich(text)
    end

    # The score-only twin of `Fuzzy.match`: same DP, same constants,
    # same optimum — but the buffers are allocated once (sized to the
    # longest path) and reused across every candidate of a keystroke,
    # and there is no position matrix to fill or walk. A keystroke over
    # thousands of paths must not churn the GC with thousands of
    # m×n Int32 arrays; the top rows' highlight positions come from
    # `Fuzzy.match` afterwards, a dozen calls at most.
    #
    # `#score` must agree with `Fuzzy.match`'s score — pinned by spec.
    # Inner loops read through raw byte pointers (`to_unsafe`): paths
    # are ASCII, and one String#char_at per DP cell (decode + bounds
    # check) dominates the runtime in dev builds.
    class Scorer
      @bonus : Array(Int32)
      @s_prev : Array(Int32)
      @s_cur : Array(Int32)
      @p_prev : Array(Int32)
      @p_cur : Array(Int32)

      def initialize(max_n : Int32)
        neg = Fuzzy::NEG_INF
        @bonus = Array.new(max_n, 0)
        @s_prev = Array.new(max_n, neg)
        @s_cur = Array.new(max_n, neg)
        @p_prev = Array.new(max_n, neg)
        @p_cur = Array.new(max_n, neg)
      end

      # Best score aligning the lowercased *dq* over the lowercased
      # *dt* (*text* is the original-case string the camelCase bonus
      # reads), or nil when *dt* does not contain *dq* as a
      # subsequence. Buffers must be at least dt.size long.
      #
      # *from* scores the suffix starting at that byte offset as if it
      # were the whole string (its first char gets the boundary bonus,
      # gap penalties count from it) — the file NAME without slicing a
      # new string per candidate. Equivalent to scoring
      # `dt.byte_slice(from)` / `text.byte_slice(from)`.
      def score(dq : String, dt : String, text : String,
                from : Int32 = 0) : Int32?
        m = dq.size
        n = dt.size - from
        return nil if m > n
        return nil if n > @bonus.size
        compute_bonus(text, from, n)
        bonus = @bonus.to_unsafe
        dqp = dq.to_unsafe
        dtp = dt.to_unsafe
        neg = Fuzzy::NEG_INF
        match = Fuzzy::MATCH_SCORE
        gap = Fuzzy::GAP_PENALTY
        consec_bonus = Fuzzy::BONUS_CONSECUTIVE

        if m == 1
          q0 = dqp[0]
          best = neg
          n.times do |i|
            next unless dtp[from + i] == q0
            s = match + bonus[i] - gap * i
            best = s if s > best
          end
          return best > neg ? best : nil
        end

        s_prev, s_cur = @s_prev, @s_cur
        p_prev, p_cur = @p_prev, @p_cur
        sp = s_prev.to_unsafe
        sc = s_cur.to_unsafe
        pp = p_prev.to_unsafe
        pc = p_cur.to_unsafe
        s_prev.fill(neg, 0, n)
        s_cur.fill(neg, 0, n)
        p_prev.fill(neg, 0, n)
        p_cur.fill(neg, 0, n)

        q0 = dqp[0]
        n.times do |i|
          if dtp[from + i] == q0
            sp[i] = match + bonus[i] - gap * i
          end
          pp[i] = i == 0 ? sp[0] : {sp[i], pp[i - 1] - gap}.max
        end

        (1...m).each do |j|
          qj = dqp[j]
          (j..(n - m + j)).each do |i|
            next unless dtp[from + i] == qj
            # See Fuzzy.match: no BONUS_CONSECUTIVE on a NEG_INF
            # diagonal — the sentinel must never enter score arithmetic.
            prev_s = sp[i - 1]
            consec = prev_s > neg ? prev_s + consec_bonus : neg
            skipped = pp[i - 1]
            best_prev = consec > skipped ? consec : skipped
            next unless best_prev > neg
            sc[i] = best_prev + match + bonus[i]
          end
          pc[j] = sc[j]
          ((j + 1)...n).each do |i|
            v = sc[i]
            alt = pc[i - 1] - gap
            pc[i] = v > alt ? v : alt
          end
          s_prev, s_cur = s_cur, s_prev
          p_prev, p_cur = p_cur, p_prev
          sp, sc = sc, sp
          pp, pc = pc, pp
          s_cur.fill(neg, 0, n)
          p_cur.fill(neg, 0, n)
        end

        best = neg
        ((m - 1)...n).each do |i|
          best = sp[i] if sp[i] > best
        end
        best > neg ? best : nil
      end

      # Fuzzy.compute_bonus into the reusable buffer (ASCII byte
      # classes; bytes >= 0x80 classify as separators, exactly like
      # non-ASCII chars fail #ascii_alphanumeric?). Indices are
      # relative to the suffix starting at *from*; its first char
      # always gets the boundary bonus (it is a name start).
      private def compute_bonus(text : String, from : Int32, n : Int32) : Nil
        bonus = @bonus.to_unsafe
        tp = text.to_unsafe
        boundary = Fuzzy::BONUS_BOUNDARY
        camel = Fuzzy::BONUS_CAMEL
        n.times do |i|
          if i == 0
            bonus[0] = boundary
          else
            prev = tp[from + i - 1]
            cur = tp[from + i]
            alnum_prev = prev.in?(48..57) || prev.in?(65..90) ||
                         prev.in?(97..122)
            bonus[i] = if !alnum_prev
                         boundary
                       elsif prev.in?(97..122) && cur.in?(65..90)
                         camel
                       elsif prev.in?(48..57) &&
                             (cur.in?(65..90) || cur.in?(97..122))
                         boundary
                       else
                         0
                       end
          end
        end
      end
    end
  end
end
