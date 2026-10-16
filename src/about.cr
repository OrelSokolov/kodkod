# kodkod — About: the "About" modal (a routed modal page — "a modal
# is just a page", see Egui::Router#modal). The app icon
# (assets/kodkod.svg, compile-time-embedded the way Egui::Icon embeds
# icon-set SVGs) over the name/version line and credits. The art is
# literal fill:#000000 — retargeted to currentColor at embed so the
# Svg tint can follow the theme (black-on-black on the dark palette
# would read as an empty modal).

require "egui-cr/egui"

module Kodkod
  class About
    # The same source `rake icons` derives every other icon from — a
    # single edit stays in sync everywhere (modal, window, packages).
    ICON = {{ read_file(__DIR__ + "/../assets/kodkod.svg") }}
          .gsub("fill:#000000", "fill:currentColor")

    # Keep in step with shard.yml.
    VERSION = "0.1.1"

    @i18n : Kodkod::I18n
    @svg : Egui::Svg
    @tint : Egui::Color32

    def initialize(@i18n)
      @tint = ART_DARK
      @svg = Egui::Svg.new(ICON, current_color: @tint)
    end

    def show(ui : Egui::Ui) : Nil
      # The theme may flip while the modal is open — re-tint once.
      tint = ui.ctx.theme.dark? ? ART_LIGHT : ART_DARK
      unless tint == @tint
        @tint = tint
        @svg = Egui::Svg.new(ICON, current_color: tint)
      end

      fg = ui.style.visuals.text_color
      muted = ui.style.visuals.fade_color(fg)
      width = ui.available_width

      # The fitted icon, centered on the modal card.
      icon_size = {150.0, width - 48.0}.min
      rect = ui.allocate_at_least(Egui::Vec2.new(width, icon_size))
      @svg.paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(rect.center.x - icon_size / 2.0, rect.top),
        Egui::Vec2.new(icon_size, icon_size)))

      line(ui, width, 34.0, "kodkod #{VERSION}", 26.0, fg, bold: true)
      line(ui, width, 22.0, @i18n.t("about.tagline"), 15.0, muted)
      line(ui, width, 22.0, @i18n.t("about.features"), 13.0, muted)
      line(ui, width, 22.0, @i18n.t("about.license"), 13.0, muted)
    end

    # One centered text line: the space is allocated through the
    # layout (so the modal card sizes to its content), the glyphs
    # themselves go through the painter (Painter#text anchors at the
    # text's left-center — hence the measure).
    private def line(ui : Egui::Ui, width : Float64, h : Float64,
                     text : String, size : Float64, color : Egui::Color32,
                     bold : Bool = false) : Nil
      rect = ui.allocate_space(Egui::Vec2.new(width, h))
      tw = ui.ctx.fonts.measure_cached(text, size).x
      ui.painter.text(
        Egui::Pos2.new(rect.center.x - tw / 2.0, rect.center.y),
        text, size, color, bold: bold)
    end

    # The artwork tint: near-white on dark palettes, near-black on
    # light ones (the Svg bake is cached per (source, tint) anyway).
    ART_LIGHT = Egui::Color32.rgb(0xE8, 0xE8, 0xE8)
    ART_DARK  = Egui::Color32.rgb(0x20, 0x20, 0x20)
  end
end
