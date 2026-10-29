# kodkod voice — the recording file format: plain RIFF/WAV, PCM16
# mono, written by us and read back by us (re-transcription feeds the
# saved PCM through the streaming engine). The reader tolerates extra
# chunks (LIST etc.) but only accepts PCM16: our writer's contract.

lib LibC
  fun fopen = fopen(path : UInt8*, mode : UInt8*) : Void*
  fun fread = fread(buf : UInt8*, size : LibC::SizeT, nmemb : LibC::SizeT, f : Void*) : LibC::SizeT
  fun fclose = fclose(f : Void*) : Int32
end

module Kodkod
  module Voice
    module Wav
      class Error < Exception
      end

      HEADER_BYTES = 44
      LE = IO::ByteFormat::LittleEndian

      # Raw libc read: Wav.read runs on the STT worker (a raw thread) —
      # Crystal IO needs an execution context there (see perevodilka's
      # engine threads for the same constraint).
      private def self.read_bytes(path : String) : Bytes
        f = LibC.fopen(path.to_unsafe, "rb".to_unsafe)
        raise Error.new("не открывается: #{path}") if f.null?
        begin
          size = File.size(path)
          buf = Bytes.new(size)
          n = LibC.fread(buf.to_unsafe, 1, size, f).to_i32
          n == size ? buf : buf[0, n]
        ensure
          LibC.fclose(f)
        end
      end

      private def self.le32(io, v : Int32) : Nil
        io.write_bytes(v, LE)
      end

      private def self.le16(io, v : Int16) : Nil
        io.write_bytes(v, LE)
      end

      private def self.i32(bytes : Bytes) : Int32
        LE.decode(Int32, bytes)
      end

      private def self.i16(bytes : Bytes) : Int16
        LE.decode(Int16, bytes)
      end

      # `pcm.size` frames of mono PCM16 at `sample_rate` Hz.
      def self.write(path : String, pcm : Slice(Int16),
                     sample_rate : Int32 = 16_000) : Nil
        data_bytes = pcm.size * 2
        File.open(path, "w") do |f|
          f.write("RIFF".to_slice)
          le32(f, HEADER_BYTES - 8 + data_bytes)
          f.write("WAVE".to_slice)
          f.write("fmt ".to_slice)
          le32(f, 16)                        # fmt chunk size
          le16(f, 1_i16)                     # PCM
          le16(f, 1_i16)                     # mono
          le32(f, sample_rate)
          le32(f, sample_rate * 2)           # byte rate
          le16(f, 2_i16)                     # block align
          le16(f, 16_i16)                    # bits per sample
          f.write("data".to_slice)
          le32(f, data_bytes)
          f.write(pcm.to_unsafe.as(Pointer(UInt8)).to_slice(data_bytes))
        end
      end

      # → {pcm frames, sample_rate}. Raises Error on anything but a
      # PCM16 WAV (any channel count is downcast naively: interleaved
      # frames are averaged — our own mono files take the fast path).
      def self.read(path : String) : {Slice(Int16), Int32}
        raise Error.new("не WAV-файл") unless File.exists?(path)
        bytes = read_bytes(path)
        raise Error.new("короткий WAV") if bytes.size < HEADER_BYTES
        raise Error.new("не RIFF") unless bytes[0, 4] == "RIFF".to_slice
        raise Error.new("не WAVE") unless bytes[8, 4] == "WAVE".to_slice

        sample_rate = 0
        channels = 1_i16
        bits = 0_i16
        pos = 12
        data = Bytes.empty
        while pos + 8 <= bytes.size
          id = bytes[pos, 4]
          size = i32(bytes[pos + 4, 4])
          body = pos + 8
          case String.new(id)
          when "fmt "
            raise Error.new("короткий fmt") if size < 16
            fmt = i16(bytes[body, 2])
            raise Error.new("не PCM") unless fmt == 1
            channels = i16(bytes[body + 2, 2])
            sample_rate = i32(bytes[body + 4, 4])
            bits = i16(bytes[body + 14, 2])
          when "data"
            avail = {size, bytes.size - body}.min
            data = bytes[body, avail]
          end
          # chunks are word-aligned: odd sizes take a pad byte
          pos = body + size + (size.odd? ? 1 : 0)
        end
        raise Error.new("нет data-чанка") if data.empty?
        raise Error.new("не 16-бит") unless bits == 16

        frames = data.size // 2 // channels
        pcm = Slice(Int16).new(frames)
        if channels == 1
          pcm.copy_from(data.to_unsafe.as(Pointer(Int16)), frames)
        else
          src = data.to_unsafe.as(Pointer(Int16))
          frames.times do |i|
            sum = 0_i32
            channels.times { |c| sum += src[i * channels + c] }
            pcm[i] = (sum // channels).to_i16
          end
        end
        {pcm, sample_rate}
      end
    end
  end
end
