# kodkod — DefPopup: the ambiguous go-to-definition chooser. A
# Ctrl+click whose word has SEVERAL indexed definitions opens this
# floating list (the framework `ctx.popup`, like QuickOpen) at the
# click position: one row per definition — name, kind, and the
# workspace-relative path with the line — Enter/click jumps, Up/Down
# walk, Esc closes. Keyboard runs BEFORE any row renders (the popup
# must claim keys even on its first frame).

require "egui-cr/egui"
require "./symbol_index"

module Kodkod
  class DefPopup
    POPUP_ID = "defpopup"
    WIDTH    = 520.0
    MAX_ROWS = 10

    property on_close : (-> Nil)? = nil

    @defs = [] of SymbolIndex::Def
    @root : String? = nil
    @anchor = Egui::Pos2.zero
    @selected = 0
    @was_open = false

    def open?(ctx : Egui::Context) : Bool
      ctx.popup_open?(POPUP_ID)
    end

    def open(ctx : Egui::Context, defs : Array(SymbolIndex::Def),
             root : String?, anchor : Egui::Pos2) : Nil
      @defs = defs.first(MAX_ROWS)
      @root = root
      @anchor = anchor
      @selected = 0
      ctx.open_popup(POPUP_ID)
    end

    def close(ctx : Egui::Context) : Nil
      ctx.close_popup(POPUP_ID)
    end

    # Renders the popup (a no-op while closed); *on_pick* receives the
    # chosen definition.
    def show(ctx : Egui::Context, &on_pick : SymbolIndex::Def ->) : Nil
      open = open?(ctx)
      if @was_open && !open && (cb = @on_close)
        cb.call
      end
      @was_open = open
      return unless open

      if ctx.input.consume_key(Egui::KeyCode::Escape)
        close(ctx)
        return
      elsif ctx.input.consume_key(Egui::KeyCode::Up)
        @selected -= 1 if @selected > 0
        ctx.request_repaint
      elsif ctx.input.consume_key(Egui::KeyCode::Down)
        @selected += 1 if @selected < @defs.size - 1
        ctx.request_repaint
      elsif ctx.input.consume_key(Egui::KeyCode::Enter)
        if (d = @defs[@selected]?)
          close(ctx)
          on_pick.call(d)
        end
        return
      end

      ctx.popup(POPUP_ID, @anchor, width: WIDTH) do |ui|
        visuals = ui.style.visuals
        dim = visuals.fade_color(visuals.text_color, 0.55)
        @defs.each_with_index do |d, i|
          rel = @root ? d.path.lchop(@root.not_nil! + "/") : d.path
          label = "#{d.name}  (#{d.kind})  #{rel}:#{d.line + 1}"
          if ui.selectable_label(i == @selected, label).clicked?
            close(ctx)
            on_pick.call(d)
            return
          end
        end
        ui.separator
        hint = Egui::RichText.new("↑↓ select · Enter jump · Esc close")
          .color(dim).size(ui.style.font_size * 0.85)
        ui.rich(hint)
      end
    end
  end
end
