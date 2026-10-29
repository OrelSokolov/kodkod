# kodkod voice — microphone capture: mono PCM16 through the rec_shim
# (ext/rec_shim.c over miniaudio, built into ext/libkodkod_rec.so and
# dlopen'd — see src/voice/sqlite.cr for the pattern). The port of
# perevodilka's src/mic.cr: a reader THREAD continuously drains the
# shim's lock-free ring into a growing buffer — the UI frame never
# participates, and a frame hitch shows up as dropped_frames, not a
# corrupted recording. Raw threads cannot use Crystal IO/sleep, so the
# idle pause is usleep (like perevodilka's engine threads).

require "./dl"

lib LibUsleep
  fun usleep(usec : UInt32) : Int32
end

module Kodkod
  module Voice
    class Recorder
      class Error < Exception
      end

      SONAMES = {"libkodkod_rec.so", "kodkod_rec.dll"}

      alias Start    = Proc(Int32, UInt32, Int32)
      alias Read     = Proc(Pointer(Int16), UInt32, UInt32)
      alias Count    = Proc(UInt32)
      alias StopFn   = Proc(Int32)

      @@handle : Void*? = Dl.open(SONAMES.to_a)

      def self.available? : Bool
        !@@handle.nil?
      end

      private def fn(type : T.class, name : String) : T forall T
        handle = @@handle.not_nil!
        ptr = Dl.sym(handle, name).not_nil!
        T.new(ptr, Pointer(Void).null)
      end

      getter sample_rate : Int32
      getter error : String?

      @read_fn : Read?
      @captured_fn : Count?
      @dropped_fn : Count?
      @stop_fn : StopFn?
      @buffer = [] of Int16
      @mutex = Thread::Mutex.new
      @reader : Thread?
      @stopping = false
      @captured = 0_u32
      @dropped = 0_u32
      @chunk = Array(Int16).new(8192, 0_i16)

      def initialize(@sample_rate = 16_000)
      end

      # Opens the device (ring ~5 s) and starts the reader thread.
      # false + error on failure (no lib, no permission, busy device…).
      def start : Bool
        unless Recorder.available?
          @error = "модуль захвата звука не найден (ext/libkodkod_rec.so)"
          return false
        end
        begin
          start_fn = fn(Start, "kodkod_rec_start")
          @read_fn = fn(Read, "kodkod_rec_read")
          @captured_fn = fn(Count, "kodkod_rec_captured")
          @dropped_fn = fn(Count, "kodkod_rec_dropped")
          @stop_fn = fn(StopFn, "kodkod_rec_stop")
        rescue e : KeyError
          @error = e.message.to_s
          return false
        end
        code = start_fn.call(@sample_rate, 5000_u32)
        case code
        when 0
          @stopping = false
          @reader = Thread.new { reader_loop }
          true
        when -2
          @error = "микрофон недоступен (нет разрешения?)"
          false
        else
          @error = "не удалось открыть микрофон (код #{code})"
          false
        end
      end

      def recording? : Bool
        !@reader.nil?
      end

      # Seconds captured (by the device callback's counter).
      def elapsed : Float64
        if (counter = @captured_fn)
          @captured = counter.call
        end
        @captured.to_f / @sample_rate
      end

      def dropped_frames : UInt32
        if (counter = @dropped_fn)
          @dropped = counter.call
        end
        @dropped
      end

      # Stops the recording and returns the whole PCM16 capture.
      def stop : Slice(Int16)
        @mutex.synchronize { @stopping = true }
        @reader.try(&.join)
        @reader = nil
        @stop_fn.try(&.call)
        pcm = Slice(Int16).new(@buffer.size) { |i| @buffer.unsafe_fetch(i) }
        @buffer.clear
        pcm
      end

      private def reader_loop : Nil
        read_fn = @read_fn.not_nil!
        until @mutex.synchronize { @stopping }
          LibUsleep.usleep(10_000)
          drain_ring(read_fn)
        end
        drain_ring(read_fn) # final drain of the ring's remains
      end

      private def drain_ring(read_fn : Read) : Nil
        loop do
          n = read_fn.call(@chunk.to_unsafe, @chunk.size.to_u32)
          break if n == 0
          @mutex.synchronize do
            @buffer.concat(@chunk[0, n.to_i32])
          end
        end
      end
    end
  end
end
