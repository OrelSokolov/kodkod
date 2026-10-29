# kodkod voice — the compact strip between the editor and the status
# bar, built as an exml COMPONENT (egui.cr's declarative markup): the
# structure lives in assets/exml/voice_strip.exml, this file is the
# "script half" — the component publishes the service's state into the
# store slots every frame and registers the toggle action; the pieces
# the fixed markup vocabulary can't express (the blinking dot, the
# spinner, the right-aligned status-tinted model chip) are custom
# elements registered through the top-level `widget` sugar.

require "./service"

module Kodkod
  class VoiceStrip < Egui::Exml::Component
    # Embed at compile time (the exml macro's read_file resolves from
    # the BUILD's cwd — the repo root under `rake build`); the
    # #template_path override below points the hot-reload stat at the
    # live file by absolute path, whatever the runtime cwd is.
    exml "assets/exml/voice_strip.exml"

    def initialize(@service : Voice::Service, @i18n : I18n,
                   @on_toggle : -> Nil)
    end

    # Absolute, so the live template hot-reloads regardless of CWD.
    def template_path : String?
      File.expand_path("../../assets/exml/voice_strip.exml", __DIR__)
    end

    def setup(rt : Egui::Exml::Runtime) : Nil
      rt.actions["voice_toggle"] = ->{ @on_toggle.call }
    end

    # Every frame, before the template renders: publish the service's
    # snapshot as the slots the markup interpolates.
    def update(ctx : Egui::Context, rt : Egui::Exml::Runtime) : Nil
      recording = @service.recording?
      rt.bools["recording"] = recording
      rt.bools["working"] = !recording && @service.working?
      rt.bools["error"] = !@service.record_error.nil?
      secs = @service.elapsed.to_i
      rt.strings["rec"] = @i18n.t("voice.status.recording",
        time: "%02d:%02d" % [secs // 60, secs % 60])
      rt.strings["queue"] = @i18n.t("voice.strip.recognizing",
        n: @service.queued_count)
      rt.strings["error"] = @service.record_error.to_s
      rt.strings["toggle"] = @i18n.t(
        recording ? "voice.record.stop_short" : "voice.record.start")
      state, _error = @service.engine_status
      rt.strings["model"] = @i18n.t("voice.strip.model",
        name: @service.engine_name)
      rt.strings["model_state"] = state.to_s
      # The blink dot animates through the whole recording.
      ctx.request_repaint if recording
    end
  end
end

# The blinking recording dot: a painter primitive, ~1 s pulse period.
widget :blink do |node, ui, ctx, rt, renderer|
  amp = 0.5 + 0.5 * Math.sin(ctx.input.time * 2.0 * Math::PI)
  dot = ui.allocate_space(Egui::Vec2.new(16.0, 12.0))
  alpha = (60 + 195 * amp).to_i.clamp(0, 255)
  ui.painter.circle_filled(dot.center, 4.5,
    Egui::Color32.rgba(0xEF, 0x53, 0x50, alpha))
end

# A small in-row spinner (the fixed vocabulary has none).
widget :spinner do |node, ui, ctx, rt, renderer|
  ui.spinner(14.0)
end

# The recognition model chip, right-aligned in the strip and tinted by
# the engine state: green = ready, amber = loading/downloading/model
# missing, red = failed / no lib. Painter-drawn inside the row flow —
# a plain trailing label sagged half a line low (the growing row
# re-centers late widgets; a painted cell centers on itself).
widget :model_chip do |node, ui, ctx, rt, renderer|
  text = rt.interpolate(node.attrs["text"]? || "{model}")
  state = rt.interpolate(node.attrs["state"]? || "{model_state}")
  color = case state
          when "ready"                 then Egui::Color32.rgb(0x4C, 0xAF, 0x50)
          when "failed", "no_lib"      then Egui::Color32.rgb(0xEF, 0x53, 0x50)
          else                              Egui::Color32.rgb(0xFF, 0xB3, 0x00)
          end
  size = ui.style.font_size
  fonts, family, bold = ctx.fonts_for_weight(
    ui.style.font_family, ui.style.font_weight, false)
  width = fonts.measure_cached(text, size).x
  # Absorb the remaining row width, then paint over a trailing cell
  # (pos.y is the text's vertical center — sokol derives the baseline).
  ui.allocate_space(Egui::Vec2.new(
    {ui.available_width - width - 8.0, 0.0}.max, 0.0))
  cell = ui.allocate_space(Egui::Vec2.new(
    width + 8.0, ui.style.spacing.interact_size.y))
  ui.painter.text(Egui::Pos2.new(cell.right - 4.0, cell.center.y),
    text, size, color, family: family, bold: bold)
end
