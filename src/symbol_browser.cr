# kodkod — SymbolBrowser: the Indexing page's debug table — every
# indexed definition in a virtualized ListView with a filter field.
#
# The filter matches BOTH cells at once: the query is a substring of
# the definition name OR of the (workspace-relative) file path — type
# "app" and you see the `app` method and everything in `src/app.cr`.
#
# Virtualization: the ScrollArea owns a stable id, so the content is
# laid out as [spacer for rows above the view][only the visible
# window of rows][spacer below] — a 50k-definition index scrolls at
# the price of a screenful of rows per frame, not 50k allocations.
# Rows are painted by hand (columns: name / kind / file / line); a
# click jumps to the definition through the app's on_jump callback.

require "egui-cr/egui"
require "./symbol_index"

module Kodkod
  class SymbolBrowser
    SCROLL_ID = Egui::Id.from("kodkod/symbol_browser")
    NAME_W    = 200.0
    KIND_W    =   70.0
    LINE_W    =   50.0

    property query = ""
    property hint = "Filter (name or file)…"
    # The workspace root — file cells display (and the filter matches)
    # paths relative to it; set by the app each frame.
    property root : String? = nil

    # (query, index version) → the filtered rows; recompute only when
    # the query changes or the indexer swapped definitions in.
    @rows : Array(SymbolIndex::Def) = [] of SymbolIndex::Def
    @rows_key : {String, UInt64}? = nil

    def initialize(@index : SymbolIndex)
    end

    # A row shows when the (case-insensitive) query is a substring of
    # the NAME or the FILE cell — both cells at once, one field.
    def self.matches?(d : SymbolIndex::Def, q : String, rel : String) : Bool
      q = q.downcase
      q.empty? || d.name.downcase.includes?(q) ||
        rel.downcase.includes?(q)
    end

    def rows : Array(SymbolIndex::Def)
      key = {query, @index.version}
      return @rows if @rows_key == key
      q = query.downcase
      @rows = @index.defs.select do |d|
        rel = root ? d.path.lchop(root.not_nil! + "/") : d.path
        self.class.matches?(d, q, rel)
      end
      @rows_key = key
      @rows
    end

    def show(ui : Egui::Ui, root : String?,
             &on_jump : SymbolIndex::Def ->) : Nil
      style = ui.style
      fonts = ui.ctx.fonts_for(style.font_family)
      fs = style.font_size
      row_h = {fonts.measure("Ag", fs).y + 2.0 * style.spacing.item_spacing.y,
               style.spacing.interact_size.y}.max
      visuals = style.visuals
      dim = visuals.fade_color(visuals.text_color, 0.55)

      # The filter field over the table.
      ui.text_edit_singleline(query, hint: hint,
        focus_id: "kodkod-symbol-filter") { |txt| self.query = txt }

      all = rows
      if all.empty?
        ui.label(@index.def_count.zero? ? @empty_index : @no_match)
        return
      end

      paint_header(ui, fonts, fs, dim)

      Egui::ScrollArea.new(id: SCROLL_ID).show(ui) do |inner|
        offset = inner.ctx.memory.data.get_vec2(SCROLL_ID,
          Egui::Vec2.zero).y
        view_h = inner.max_rect.height
        total = all.size
        first = (offset / row_h).floor.to_i.clamp(0, {total, 0}.max)
        last = {first + (view_h / row_h).ceil.to_i + 1, total}.min
        # Rows are laid GAPLESS: item_spacing.y is zeroed for the rows
        # region (save/restore — ctx.style is shared). Gaps between
        # rows made the hover fill flicker row to row as the pointer
        # crossed them, and each row would add spacing to the layout,
        # desyncing the virtualization spacers from the real offsets.
        old_spacing = inner.ctx.style.spacing.item_spacing
        inner.ctx.style.spacing.item_spacing =
          Egui::Vec2.new(old_spacing.x, 0.0)
        begin
          # Spacers replace the off-screen rows (see the class comment).
          inner.allocate_space(Egui::Vec2.new(0.0, first.to_f64 * row_h))
          painter = inner.painter
          (first...last).each do |i|
            d = all[i]
            rect = inner.allocate_at_least(
              Egui::Vec2.new(inner.available_width, row_h))
            resp = inner.interact(rect, inner.next_widget_id,
              Egui::Sense::Click)
            if resp.hovered?
              painter.rect(rect, 4.0, visuals.button_weak)
            end
            rel = root ? d.path.lchop(root.not_nil! + "/") : d.path
            x = rect.left + style.spacing.button_padding.x
            y = rect.center.y
            painter.text(Egui::Pos2.new(x, y), d.name, fs,
              visuals.text_color, family: style.font_family)
            painter.text(Egui::Pos2.new(x + NAME_W, y), d.kind.to_s, fs,
              visuals.hyperlink_color, family: style.font_family)
            painter.text(Egui::Pos2.new(x + NAME_W + KIND_W, y), rel, fs,
              dim, family: style.font_family)
            line_lbl = (d.line + 1).to_s
            painter.text(Egui::Pos2.new(
              rect.right - LINE_W - style.spacing.button_padding.x -
              fonts.measure(line_lbl, fs).x, y), line_lbl, fs, dim,
              family: style.font_family)
            if resp.clicked?
              on_jump.call(d)
            end
          end
          inner.allocate_space(Egui::Vec2.new(0.0, (total - last) * row_h))
        ensure
          inner.ctx.style.spacing.item_spacing = old_spacing
        end
      end

      footer_text = @rows_shown.gsub("%{shown}", all.size.to_s)
        .gsub("%{total}", @index.def_count.to_s)
      footer = Egui::RichText.new(footer_text).color(dim).size(fs * 0.85)
      ui.rich(footer)
    end

    private def paint_header(ui : Egui::Ui, fonts : Egui::Fonts,
                             fs : Float64, dim : Egui::Color32) : Nil
      pad = ui.style.spacing.button_padding.x
      painter = ui.painter
      rect = ui.allocate_at_least(
        Egui::Vec2.new(ui.available_width, fonts.measure("Ag", fs).y))
      y = rect.center.y
      painter.text(Egui::Pos2.new(rect.left + pad, y), @col_name, fs,
        dim, family: ui.style.font_family, bold: true)
      painter.text(Egui::Pos2.new(rect.left + pad + NAME_W, y), @col_kind,
        fs, dim, family: ui.style.font_family, bold: true)
      painter.text(Egui::Pos2.new(rect.left + pad + NAME_W + KIND_W, y),
        @col_file, fs, dim, family: ui.style.font_family, bold: true)
      painter.text(Egui::Pos2.new(rect.right - LINE_W - pad, y), @col_line,
        fs, dim, family: ui.style.font_family, bold: true)
      ui.separator
    end

    # Localized strings, set by the app each frame (see I18n).
    property empty_index : String = "Nothing indexed yet."
    property no_match : String = "No matches."
    property rows_shown : String = "%{shown} of %{total}"
    property col_name : String = "Name"
    property col_kind : String = "Kind"
    property col_file : String = "File"
    property col_line : String = "Line"
  end
end
