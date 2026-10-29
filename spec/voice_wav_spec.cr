require "spec"
require "file_utils"
require "../src/voice/wav"

describe Kodkod::Voice::Wav do
  it "round-trips mono PCM16" do
    dir = File.join(Dir.tempdir, "kodkod-wav-#{Random.new.hex(6)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "a.wav")
    pcm = Slice(Int16).new(16_000) { |i| (i % 100).to_i16 } # 1 s
    Kodkod::Voice::Wav.write(path, pcm, 16_000)
    back, rate = Kodkod::Voice::Wav.read(path)
    rate.should eq 16_000
    back.size.should eq pcm.size
    back.to_a.should eq pcm.to_a
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "reads a non-default sample rate" do
    dir = File.join(Dir.tempdir, "kodkod-wav-#{Random.new.hex(6)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "b.wav")
    Kodkod::Voice::Wav.write(path, Slice[1_i16, -2_i16, 3_i16], 8_000)
    back, rate = Kodkod::Voice::Wav.read(path)
    rate.should eq 8_000
    back.to_a.should eq [1, -2, 3]
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "downmixes stereo to mono" do
    # Hand-built stereo WAV: L/R pairs averaged (1,3)→2, (-2,2)→0.
    pcm = Slice(Int16).new(4) { |i| [1_i16, 3_i16, -2_i16, 2_i16][i] }
    stereo = Slice(Int16).new(2) { |i| i.zero? ? 2_i16 : 0_i16 }
    data = pcm.to_unsafe.as(Pointer(UInt8)).to_slice(8)
    stereo_bytes = stereo.to_unsafe.as(Pointer(UInt8)).to_slice(4)
    dir = File.join(Dir.tempdir, "kodkod-wav-#{Random.new.hex(6)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "st.wav")
    File.open(path, "w") do |f|
      le = IO::ByteFormat::LittleEndian
      f.write("RIFF".to_slice)
      f.write_bytes((36 + 8).to_i32, le)
      f.write("WAVE".to_slice)
      f.write("fmt ".to_slice)
      f.write_bytes(16.to_i32, le)
      f.write_bytes(1.to_i16, le)     # PCM
      f.write_bytes(2.to_i16, le)     # stereo
      f.write_bytes(16_000.to_i32, le)
      f.write_bytes(64_000.to_i32, le)
      f.write_bytes(4.to_i16, le)
      f.write_bytes(16.to_i16, le)
      f.write("data".to_slice)
      f.write_bytes(8.to_i32, le)
      f.write(data)
    end
    back, _rate = Kodkod::Voice::Wav.read(path)
    back.to_a.should eq [2, 0]
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "rejects a non-WAV file" do
    dir = File.join(Dir.tempdir, "kodkod-wav-#{Random.new.hex(6)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "x.wav")
    File.write(path, "not a wav at all")
    expect_raises(Kodkod::Voice::Wav::Error) { Kodkod::Voice::Wav.read(path) }
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
