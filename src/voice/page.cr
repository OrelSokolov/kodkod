# kodkod voice — the Voice page (root/voice), EXML edition: the page
# STRUCTURE lives in assets/voice.exml (the heading, the record
# section, the queue header, a <repeat> over the recordings); this
# class owns everything the markup can't express. That is the exml
# split: it publishes the model into the store (named string/bool
# slots + the "recordings" rows), registers the named actions the
# markup fires, and renders the custom elements outside the built-in
# vocabulary (the model expander, the big record button, the colored
# labels, the voice cards with badges and icon-only actions). The
# service (src/voice/service.cr) still owns all state — the page only
# reads snapshots and fires actions.

require "./service"

module Kodkod
  class VoicePage
    getter service : Voice::Service

    # "Insert this transcript into the active editor" — set by the app
    # (it owns editors and egui context); the page stays editor-free.
    property on_insert : Proc(String, Nil)?
    # Toggle state: nil = current project only.
    property? all_projects : Bool = false

    RED   = Egui::Color32.rgb(0xEF, 0x53, 0x50)
    GREEN = Egui::Color32.rgb(0x4C, 0xAF, 0x50)
    AMBER = Egui::Color32.rgb(0xFF, 0xB3, 0x00)

    # The markup: the live file wins (hot reload — edit
    # assets/voice.exml while the app runs), the compile-time copy is
    # the standalone-binary fallback.
    VOICE_EXML = {{ read_file(__DIR__ + "/../../assets/voice.exml") }}
    CUSTOM_ELEMENTS = %w(model_section record_button record_error
                         dim_label voice_card scroll)

    @project : String? = nil
    @rows_cache = [] of Voice::DB::Recording
    @rt = Egui::Exml::Runtime.new
    @renderer = Egui::Exml::Renderer.new
    @doc : Egui::Exml::Document

    def initialize(@service : Voice::Service, @i18n : I18n)
      @doc = load_exml
      lint_exml
      register_custom_elements
      register_actions
    end

    private def exml_path : String?
      [ENV["KODKOD_VOICE_EXML"]?,
       File.join(__DIR__, "..", "..", "assets", "voice.exml")]
        .compact.find { |c| File.file?(c) }
    end

    private def load_exml : Egui::Exml::Document
      if (path = exml_path)
        Egui::Exml::Document.load(path)
      else
        Egui::Exml::Document.parse(VOICE_EXML)
      end
    end

    # Vocabulary lint: markup drift lands in the console at startup
    # and on every hot reload, not as a silently misrendering widget.
    private def lint_exml : Nil
      Egui::Exml.validate(@doc, known_custom: CUSTOM_ELEMENTS)
        .each { |issue| STDERR.puts "exml: #{issue}" }
    end

    private def t(key : String, **args) : String
      @i18n.t(key, **args)
    end

    # The frame: publish the model, then walk the markup tree. The
    # page wrapper (route/title) belongs to app.cr's router; only the
    # page BODY is markup.
    def render(ui : Egui::Ui, project : String?) : Nil
      @project = project
      lint_exml if @doc.reload_if_changed
      sync_store
      if page = @doc.page("root/voice")
        @renderer.render_each(page, ui, ui.ctx, @rt)
      end
    end

    # --- model → store ---------------------------------------------------

    private def sync_store : Nil
      s = @rt.strings
      b = @rt.bools

      s["title"] = t("voice.title")
      s["rec_button"] = @service.recording? ?
        t("voice.record.stop", time: fmt_time(@service.elapsed)) :
        t("voice.record.start")
      if (err = @service.record_error)
        b["record_error"] = true
        s["record_error"] = err
      else
        b["record_error"] = false
      end
      s["record_hint"] = t("voice.record.hint")

      rows = @service.list(@all_projects ? nil : @project)
      @rows_cache = rows
      s["queue_title"] = t("voice.queue.title") + " (#{rows.size})"
      s["all_projects_label"] = t("voice.queue.all_projects")
      s["retranscribe_all_label"] = t("voice.queue.retranscribe_all")
      b["all_projects"] = @all_projects
      b["has_finished"] = rows.any? { |r| r.status.in?({"done", "failed"}) }
      b["has_rows"] = !rows.empty?
      s["queue_empty"] = t("voice.queue.empty")

      @rt.rows["recordings"] = rows.map do |r|
        meta = Time.unix(r.created_at).to_local.to_s("%H:%M:%S") + " · " +
               fmt_time(r.duration_ms.to_f / 1000)
        meta += " · #{r.project}" if @all_projects && !r.project.empty?
        {
          "id"         => r.id.to_s,
          "status"     => r.status,
          "meta"       => meta,
          "transcript" => r.transcript.to_s,
          "error"      => r.error.to_s,
        }
      end
    end

    # --- actions (markup fires these by name) ----------------------------

    private def register_actions : Nil
      a = @rt.actions
      a["toggle_record"] = ->{
        if @service.recording?
          @service.stop_recording
        else
          @service.start_recording(@project.to_s, nil)
        end
      }
      a["all_projects_changed"] = ->{
        @all_projects = @rt.bool("all_projects")
      }
      a["retranscribe_all"] = ->{ @service.retranscribe_all }
      # Card actions: <repeat> writes the firing row's index into the
      # root store as "_i" just before the action runs.
      a["row_insert"] = ->{
        if (row = fired_row) && (tr = row.transcript)
          @on_insert.try(&.call(tr))
        end
      }
      a["row_retry"] = ->{
        if row = fired_row
          @service.retranscribe(row.id)
        end
      }
      a["row_delete"] = ->{
        if row = fired_row
          @service.delete(row.id)
        end
      }
    end

    private def fired_row : Voice::DB::Recording?
      return unless (i = @rt.string("_i").to_i?)
      @rows_cache[i]?
    end

    # --- custom elements --------------------------------------------------

    private def register_custom_elements : Nil
      r = @renderer
      r.on("model_section") { |_n, ui, _ctx, _rt, _r| render_model(ui) }
      r.on("record_button") { |_n, ui, _ctx, rt, _r|
        if ui.big_button(rt.string("rec_button")).clicked?
          rt.fire("toggle_record")
        end
      }
      r.on("record_error") { |_n, ui, _ctx, rt, _r|
        ui.rich(Egui::RichText.new(rt.string("record_error")).color(RED))
      }
      r.on("dim_label") { |n, ui, _ctx, rt, _r|
        fg = ui.style.visuals.text_color
        ui.rich(Egui::RichText.new(rt.interpolate(n.attrs["text"]? || ""))
          .color(Egui::Color32.rgba(fg.r, fg.g, fg.b, 150)))
      }
      r.on("voice_card") { |_n, ui, _ctx, rt, _r| render_card(ui, rt) }
      # <scroll> — a vertical scroll area around the children. The
      # routed page body (Context#page) does NOT get the central
      # panel's automatic overflow-y: auto, so the queue needs this
      # once the cards outgrow the window.
      r.on("scroll") { |node, ui, ctx, rt, r|
        ui.scroll_area { |inner| r.render_each(node, inner, ctx, rt) }
      }
    end

    # --- model status / download --------------------------------------

    private def render_model(ui : Egui::Ui) : Nil
      fg = ui.style.visuals.text_color
      dim = Egui::Color32.rgba(fg.r, fg.g, fg.b, 160)
      state, error = @service.engine_status

      ui.expander(t("voice.model.title"), default_open: true) do |body|
        case state
        when :no_lib
          body.rich(Egui::RichText.new(t("voice.model.no_lib")).color(RED))
          body.rich(Egui::RichText.new(t("voice.model.no_lib_hint")).color(dim))
        when :downloading
          @service.models.poll_download
          file = @service.models.downloading_file.to_s
          body.label(t("voice.model.downloading", file: file))
          if @service.models.expected_bytes > 0
            body.progress_bar(@service.models.progress,
              text: "#{@service.models.done_bytes // 1_048_576} / #{@service.models.expected_bytes // 1_048_576} MiB")
          else
            body.spinner
          end
          if body.button(t("voice.model.cancel")).clicked?
            @service.models.cancel_download
          end
        when :no_models
          body.label(t("voice.model.missing"))
          if body.button(t("voice.model.download")).clicked?
            @service.models.start_download
          end
        when :loading
          body.horizontal do |row|
            row.spinner
            row.label(t("voice.model.loading"))
          end
        when :ready
          body.rich(Egui::RichText.new(t("voice.model.ready")).color(GREEN))
        when :failed
          body.rich(Egui::RichText.new(
            t("voice.model.failed", error: error.to_s[0, 200])).color(RED))
          if body.button(t("voice.model.retry")).clicked?
            @service.retry_engine
          end
        end
      end
    end

    # --- one voice card ------------------------------------------------
    #
    # Rendered per <repeat> row: the row's fields arrive in the scope
    # as rec.* strings. Messenger-style card — a status-tinted icon
    # badge, a meta line (time · duration · project), the transcript
    # body, and quiet icon-only actions pulled to the right edge — on
    # a panel fill lifted toward the text color with a faint outline.

    private def render_card(ui : Egui::Ui, rt : Egui::Exml::Runtime) : Nil
      v = ui.style.visuals
      fg = v.text_color
      dim = Egui::Color32.rgba(fg.r, fg.g, fg.b, 150)
      status = rt.string("rec.status")
      row_id = rt.string("rec.id")
      transcript = rt.string("rec.transcript")
      accent, icon = status_style(status)
      small = ui.style.font_size * 0.9

      fill = v.panel_fill.lerp(fg, v.dark ? 0.05 : 0.04)
      edge = Egui::Color32.rgba(fg.r, fg.g, fg.b, v.dark ? 25 : 45)
      ui.frame(fill: fill, stroke: edge, rounding: 10.0,
               margin: Egui::Vec2.new(12.0, 10.0)) do |card|
        card.horizontal do |head|
          badge(head, icon, accent)
          head.rich(Egui::RichText.new(rt.string("rec.meta"))
            .size(small).color(dim))

          # Status + actions hug the right edge. The spacer is sized
          # from the MEASURED status text width plus the buttons, so
          # the cluster never overflows the card edge (a constant
          # reserve is wrong the moment the status line runs long).
          status_txt = status_label(status)
          gap = head.style.spacing.item_spacing.x
          n_actions = 1 +
                      (status == "done" && !transcript.empty? ? 1 : 0) +
                      (status.in?({"done", "failed"}) ? 1 : 0)
          needed = (status == "running" ? 12.0 + gap : 0.0) +
                   head.fonts.measure_cached(status_txt, small).x +
                   n_actions * action_width(head) +
                   (n_actions + 1) * gap # item_spacing within the cluster
          head.allocate_space(Egui::Vec2.new(
            {head.available_width - needed, 4.0}.max, 0.0))
          head.spinner(12.0) if status == "running"
          head.rich(Egui::RichText.new(status_txt).size(small).color(accent))
          if status == "done" && !transcript.empty?
            insert = Egui::Icon.from_file(:lucide, :corner_down_left, tint: GREEN)
            if icon_action(head, insert,
                 t("voice.queue.insert"), "voice-ins-#{row_id}").clicked?
              rt.fire("row_insert")
            end
          end
          if status.in?({"done", "failed"})
            retry_icon = Egui::Icon.from_file(:lucide, :rotate_ccw, tint: fg)
            if icon_action(head, retry_icon,
                 t("voice.queue.retry"), "voice-retry-#{row_id}").clicked?
              rt.fire("row_retry")
            end
          end
          delete = Egui::Icon.from_file(:lucide, :trash, tint: RED)
          if icon_action(head, delete,
               t("voice.queue.delete"), "voice-del-#{row_id}").clicked?
            rt.fire("row_delete")
          end
        end

        case status
        when "done"
          card.label(transcript, wrap: true)
        when "failed"
          card.rich(Egui::RichText.new(rt.string("rec.error"))
            .size(small).color(RED))
        end
      end
    end

    # Status → {accent color, badge icon}. The lucide icons are
    # embedded at compile time (#Icon.from_file), so the case spells
    # the names out as literals.
    private def status_style(status : String) : Tuple(Egui::Color32, Egui::Svg)
      case status
      when "done"
        {GREEN, Egui::Icon.from_file(:lucide, :audio_waveform, tint: GREEN)}
      when "failed"
        {RED, Egui::Icon.from_file(:lucide, :circle_x, tint: RED)}
      when "running"
        {AMBER, Egui::Icon.from_file(:lucide, :mic, tint: AMBER)}
      else
        {AMBER, Egui::Icon.from_file(:lucide, :clock, tint: AMBER)}
      end
    end

    private def status_label(status : String) : String
      case status
      when "done"    then t("voice.status.done")
      when "running" then t("voice.status.running")
      when "failed"  then t("voice.status.failed")
      else                t("voice.status.queued")
      end
    end

    # Round status badge — the voice-bubble look: the accent at low
    # alpha for the fill, the glyph stroked in the full accent.
    BADGE = 30.0

    private def badge(ui : Egui::Ui, icon : Egui::Svg,
                      accent : Egui::Color32) : Nil
      rect = ui.allocate_space(Egui::Vec2.new(BADGE, BADGE))
      c = rect.center
      ui.painter.circle_filled(c, BADGE / 2.0,
        Egui::Color32.rgba(accent.r, accent.g, accent.b, 36))
      icon.paint(ui, Egui::Rect.from_min_size(
        Egui::Pos2.new(c.x - 8.0, c.y - 8.0), Egui::Vec2.new(16.0, 16.0)))
    end

    # Reserved width of one icon-only action button, mirroring
    # Button#ui's math exactly: min_size floors the (empty) text box
    # FIRST, the icon width rides on top. Do NOT feed this whole
    # value back as the button's min_size — the floor applies before
    # the icon is added, so that would double-count the glyph (a
    # 48.8px reservation made 69.6px buttons and squeezed delete off
    # the card edge).
    private def action_width(ui : Egui::Ui) : Float64
      s = ui.style
      {s.spacing.button_padding.x * 2.0, 28.0}.max +
        s.font_size * Egui::Fonts::LINE_H_FACTOR
    end

    private def icon_action(ui : Egui::Ui, icon : Egui::Svg, tooltip : String,
                            id : String) : Egui::Response
      button = Egui::Button.new("", id: id)
        .icon(icon)
        .min_size(Egui::Vec2.new(28.0, 22.0))
      ui.add(button).on_hover_text(tooltip)
    end

    private def fmt_time(seconds : Float64) : String
      total = seconds.to_i
      "%02d:%02d" % [total // 60, total % 60]
    end
  end
end
