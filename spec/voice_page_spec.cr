# Voice page (EXML edition) specs: the markup lints against the exml
# vocabulary, and a headless frame renders the queue — cards with
# badges, right-aligned actions inside the card edge, status text and
# the wrapped transcript — straight from assets/voice.exml.

require "spec"
require "file_utils"
require "egui-cr/egui"
require "../src/i18n"
require "../src/voice/service"
require "../src/voice/page"

class PageTranscriber < Kodkod::Voice::Transcriber
  def name : String
    "fake"
  end

  def transcribe(pcm : Slice(Int16), sample_rate : Int32) : String
    "привет мир — расшифрованная запись"
  end
end

describe Kodkod::VoicePage do
  it "lints assets/voice.exml against the exml vocabulary" do
    doc = Egui::Exml::Document.parse(Kodkod::VoicePage::VOICE_EXML)
    Egui::Exml.validate(doc,
      known_custom: Kodkod::VoicePage::CUSTOM_ELEMENTS).should be_empty
  end

  it "renders the queue cards from the markup" do
    dir = File.join(Dir.tempdir, "kodkod-voice-page-#{Random.new.hex(6)}")
    fake = PageTranscriber.new
    service = Kodkod::Voice::Service.new(dir, ->{ fake.as(Kodkod::Voice::Transcriber?) })
    pcm = Slice(Int16).new(1600) { |i| (i % 7).to_i16 }
    service.ingest(pcm, 16_000, "/proj", nil)
    deadline = Time.monotonic + 5.seconds
    until service.list(nil).any?(&.status.==("done")) || Time.monotonic > deadline
      sleep 0.02
    end
    service.list(nil).any?(&.status.==("done")).should be_true

    page = Kodkod::VoicePage.new(service, Kodkod::I18n.new("ru"))
    screen = Egui::Rect.from_min_size(Egui::Pos2.zero, Egui::Vec2.new(520.0, 700.0))
    ctx = Egui::Context.new
    3.times do |i|
      ctx.begin_frame(Egui::RawInput.new(screen, [] of Egui::Event, 0.016 * (i + 1)))
      ctx.central_panel do |ui|
        page.render(ui, "/proj")
      end
      ctx.end_frame
    end

    texts = ctx.painter.commands.select(Egui::TextCmd).map(&.text)
    texts.should contain("Голосовые сообщения")
    texts.should contain("Записи (1)")
    texts.should contain("готово")
    texts.should contain("привет мир — расшифрованная запись")

    # The card: the full-width rounded fill that carries the badge
    # (a filled circle) — the model expander paints one too, so the
    # badge anchor tells them apart.
    badges = ctx.painter.commands.select(Egui::CircleCmd)
      .select { |c| (c.radius - 15.0).abs < 0.5 && c.fill }
    badges.size.should eq(1)
    badge = badges.first
    cards = ctx.painter.commands.select(Egui::RectCmd)
      .select { |r| r.rounding > 5.0 && r.fill && r.rect.width > 400.0 &&
                    r.rect.contains?(badge.center) }
    cards.size.should eq(1)
    card = cards.first.rect

    # Every interact widget inside the card (the icon actions) ends
    # within the card's right edge.
    ctx.memory.widget_rects.each do |_, r|
      next unless r.top >= card.top - 0.5 && r.bottom <= card.bottom + 0.5
      r.right.should be <= card.right + 0.5
    end
  ensure
    service.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end
end
