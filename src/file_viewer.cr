# kodkod — FileViewer: the image tab. Raster files (PNG and the other
# stb_image formats) render as GPU textures through Context#load_image;
# SVG re-rasterizes through the egui-cr NanoSVG cache at each displayed
# size (crisp at any zoom, same pipeline as the Svg widget). The image
# fits into the tab (aspect preserved, centered); the wheel zooms
# (×1.1 a notch, like the plot) around the view center, a drag pans,
# and a double-click resets to the fitted view.

require "egui-cr/egui"

module Kodkod
  class FileViewer
    # Extensions this tab opens: PNG/SVG plus the raster formats
    # stb_image decodes for free.
    RASTER_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga"}
    SVG_EXTS    = {".svg"}

    getter path : String
    getter error : String? = nil
    # Intrinsic pixel size (SVG: viewBox user units); rasters resolve
    # theirs at #show (the size probe needs the texture registry).
    getter intrinsic : Egui::Vec2? = nil
    # Zoom relative to the fit-in-view scale: 1.0 = fitted.
    property zoom : Float64 = 1.0

    @pan : Egui::Vec2 = Egui::Vec2.zero
    @svg_source : String? = nil
    @svg : Egui::Svg? = nil
    @texture : UInt64 = 0_u64

    # Parse failures land in #error — the tab still opens and shows
    # the message instead of a half-broken viewer.
    def initialize(@path)
      begin
        ext = File.extname(@path).downcase
        if SVG_EXTS.includes?(ext)
          source = File.read(@path)
          if (img = Egui::NanoSvgCr.image(source, Egui::Svg::BLACK))
            @svg_source = source
            @svg = Egui::Svg.new(source)
            @intrinsic = Egui::Vec2.new(img.width.to_f64, img.height.to_f64)
          else
            @error = "Cannot parse SVG (no usable size): #{name}"
          end
        elsif !RASTER_EXTS.includes?(ext)
          @error = "Cannot view this file — unsupported type: " \
                   "#{ext.empty? ? "no extension" : ext}"
        end
      rescue e : IO::Error | File::Error
        @error = "Cannot read #{name}: #{e.message}"
      end
    end

    def self.supported?(path : String) : Bool
      ext = File.extname(path).downcase
      RASTER_EXTS.includes?(ext) || SVG_EXTS.includes?(ext)
    end

    def svg? : Bool
      !@svg_source.nil?
    end

    def name : String
      File.basename(@path)
    end

    def reset_view : Nil
      @zoom = 1.0
      @pan = Egui::Vec2.zero
    end

    # The status-bar line: kind · W×H · zoom% (size blank until the
    # raster probe answered).
    def status_info : String
      size = (i = @intrinsic) ? "#{i.x.to_i}×#{i.y.to_i}" : "—"
      kind = svg? ? "SVG" : File.extname(@path).downcase.sub(/^\./, "").upcase
      "#{kind}  #{size}  #{(@zoom * 100).round.to_i}%"
    end

    def show(ui : Egui::Ui) : Nil
      if (msg = ensure_loaded(ui.ctx))
        ui.label(msg)
        return
      end
      avail = Egui::Vec2.new(ui.available_width, ui.available_height)
      rect = ui.allocate_at_least(avail)
      response = ui.interact(rect, ui.next_widget_id,
        Egui::Sense.click_and_drag)

      input = ui.ctx.input
      if response.hovered? && input.scroll.y != 0.0
        # Wheel-up zooms in, one notch one step (plot.cr's rhythm).
        step = input.scroll.y < 0.0 ? 1.1 : 1.0 / 1.1
        @zoom = (@zoom * step).clamp(0.05, 32.0)
        ui.ctx.request_repaint
      end
      reset_view if response.double_clicked?
      if response.dragged?
        @pan += response.drag_delta
        ui.ctx.request_repaint
      end
      response.on_hover_and_drag_cursor(Egui::CursorIcon::AllScroll)

      center = rect.center + @pan

      if (svg = @svg)
        # Svg#paint fits the art into the rect (aspect kept, centered),
        # so a rect of viewport×zoom displays at zoom×fit — the pan
        # just moves that rect's center.
        size = Egui::Vec2.new(avail.x * @zoom, avail.y * @zoom)
        svg.paint(ui, Egui::Rect.from_min_size(
          Egui::Pos2.new(center.x - size.x / 2.0, center.y - size.y / 2.0),
          size))
      elsif (intrinsic = @intrinsic)
        fit = {avail.x / intrinsic.x, avail.y / intrinsic.y}.min * @zoom
        w = intrinsic.x * fit
        h = intrinsic.y * fit
        img_rect = Egui::Rect.from_min_size(
          Egui::Pos2.new(center.x - w / 2.0, center.y - h / 2.0),
          Egui::Vec2.new(w, h))
        painter = ui.painter
        # Backing for transparent regions plus a visible frame (the
        # backing alone is too close to the panel), then the texture —
        # NEAREST once past 3× magnification so pixels inspect as pixels.
        painter.rect(img_rect, 0.0, Egui::Color32.rgb(0x26, 0x26, 0x26),
          Egui::Color32.rgb(0x70, 0x70, 0x70), 1.0)
        painter.image(img_rect, @texture, nearest: fit > 3.0)
      end
    end

    # Raster lazy-load: texture + intrinsic size need a context, so
    # they resolve on the first #show. Returns the error message when
    # the file cannot be shown (nil = fine).
    private def ensure_loaded(ctx : Egui::Context) : String?
      return @error if @error
      return nil if @svg_source
      @texture = ctx.load_image(@path) if @texture.zero?
      @intrinsic ||= ctx.image_size(@path)
      @error = "Cannot decode image: #{name}" if @texture.zero?
      @error
    end
  end
end
