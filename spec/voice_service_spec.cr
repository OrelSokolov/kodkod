require "spec"
require "file_utils"
require "../src/voice/service"

# A fake engine for headless queue tests: no libgigastt, no model —
# the service only needs a Transcriber.
class FakeTranscriber < Kodkod::Voice::Transcriber
  property text : String = "привет мир"
  property fail : Bool = false

  def name : String
    "fake"
  end

  def transcribe(pcm : Slice(Int16), sample_rate : Int32) : String
    raise Kodkod::Voice::Service::Error.new("движок сломался") if @fail
    @text
  end
end

describe Kodkod::Voice::Service do
  it "word-wraps transcripts to <=120 chars with a trailing newline" do
    # A long single-line transcript: every line fits, ends with \n.
    long = (Array.new(60, "слово")).join(' ') # 300 chars, 5 per word
    out = Kodkod::Voice::Service.wrap_text(long)
    out.lines.all? { |l| l.size <= 120 }.should be_true
    out.ends_with?('\n').should be_true
    # Wrapping at spaces only: no words were split.
    out.gsub('\n', ' ').split(' ').reject(&.empty?).should eq Array.new(60, "слово")

    # Short transcript: single line + newline.
    Kodkod::Voice::Service.wrap_text("привет мир").should eq "привет мир\n"

    # Existing paragraphs survive; a >width word stays whole. (Crystal's
    # #lines strips the newline terminators.)
    out2 = Kodkod::Voice::Service.wrap_text("аб\n" + "д" * 150)
    out2.lines[0].should eq "аб"
    out2.lines[1].should eq ("д" * 150)
    out2.ends_with?('\n').should be_true

    # Blank input inserts nothing.
    Kodkod::Voice::Service.wrap_text("  ").should eq ""
  end

  it "runs an ingested recording through the queue to done + finished" do
    dir = File.join(Dir.tempdir, "kodkod-voice-#{Random.new.hex(6)}")
    fake = FakeTranscriber.new
    service = Kodkod::Voice::Service.new(dir, ->{ fake.as(Kodkod::Voice::Transcriber?) })

    pcm = Slice(Int16).new(1600) { |i| (i % 7).to_i16 } # 0.1 s
    service.ingest(pcm, 16_000, "/proj", "doc-1")
    service.preload

    finished = wait_for(service) { |f| !f.empty? }
    finished.size.should eq 1
    finished[0].ok.should be_true
    finished[0].transcript.should eq "привет мир"

    row = service.db.get(finished[0].id).not_nil!
    row.status.should eq "done"
    row.transcript.should eq "привет мир"
    row.engine.should eq "fake"
    row.duration_ms.should eq 100
    File.exists?(service.wav_path(row)).should be_true

    # Auto-insert target consumed exactly once.
    service.auto_insert_target(finished[0].id).should eq "doc-1"
    service.auto_insert_target(finished[0].id).should be_nil

    # The loaded engine names itself for the voice strip.
    service.engine_name.should eq "fake"
  ensure
    service.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "marks a row failed when the engine raises, and retry heals it" do
    dir = File.join(Dir.tempdir, "kodkod-voice-#{Random.new.hex(6)}")
    fake = FakeTranscriber.new
    fake.fail = true
    service = Kodkod::Voice::Service.new(dir, ->{ fake.as(Kodkod::Voice::Transcriber?) })

    service.ingest(Slice[1_i16, 2_i16], 16_000, "/p", nil)
    finished = wait_for(service) { |f| !f.empty? }
    finished[0].ok.should be_false
    row = service.db.get(finished[0].id).not_nil!
    row.status.should eq "failed"
    row.error.should eq "движок сломался"

    fake.fail = false
    service.retranscribe(row.id)
    healed = wait_for(service) { |f| f.any?(&.ok) }
    healed.size.should eq 1
    service.db.get(row.id).not_nil!.transcript.should eq "привет мир"
  ensure
    service.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "fails rows when the factory yields no engine" do
    dir = File.join(Dir.tempdir, "kodkod-voice-#{Random.new.hex(6)}")
    service = Kodkod::Voice::Service.new(dir, ->{ nil.as(Kodkod::Voice::Transcriber?) })
    service.ingest(Slice[1_i16], 16_000, "/p", nil)
    finished = wait_for(service) { |f| !f.empty? }
    finished[0].ok.should be_false
    service.db.get(finished[0].id).not_nil!.status.should eq "failed"
  ensure
    service.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "deletes a recording with its wav" do
    dir = File.join(Dir.tempdir, "kodkod-voice-#{Random.new.hex(6)}")
    fake = FakeTranscriber.new
    fake.fail = true # keep the row around for delete
    service = Kodkod::Voice::Service.new(dir, ->{ fake.as(Kodkod::Voice::Transcriber?) })
    service.ingest(Slice[1_i16], 16_000, "/p", nil)
    finished = wait_for(service) { |f| !f.empty? }
    id = finished[0].id
    path = service.wav_path(service.db.get(id).not_nil!)
    File.exists?(path).should be_true
    service.delete(id)
    service.db.get(id).should be_nil
    File.exists?(path).should be_false
  ensure
    service.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "reports engine status per the model bundle state" do
    dir = File.join(Dir.tempdir, "kodkod-voice-#{Random.new.hex(6)}")
    fake = FakeTranscriber.new
    service = Kodkod::Voice::Service.new(dir, ->{ fake.as(Kodkod::Voice::Transcriber?) })
    service.engine_status[0].should eq :no_models # no bundle files yet
    service.ingest(Slice[1_i16], 16_000, "/p", nil)
    wait_for(service) { |f| !f.empty? }
    # The fake factory bypasses the bundle; with files faked complete
    # the worker's own state (:ready after first use) shows through.
    Kodkod::Voice::ModelStore::FILES.each_key do |name|
      File.write(File.join(dir, "models", name), "x")
    end
    service.engine_status[0].should eq :ready
  ensure
    service.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

end

# Poll take_finished until the block says stop (or timeout).
def wait_for(service, timeout = 5.0, &) : Array(Kodkod::Voice::Service::Finished)
  deadline = Time.monotonic + timeout.seconds
  loop do
    finished = service.take_finished
    return finished if yield finished
    raise "timeout waiting for the voice worker" if Time.monotonic > deadline
    sleep 0.02
  end
end
