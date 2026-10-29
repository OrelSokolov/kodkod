# kodkod voice — GigaAM (gigastt) recognition engine over dlopen, the
# port of perevodilka's src/gigastt_ffi.cr onto runtime-resolved
# function pointers (see src/voice/sqlite.cr for the same trick): the
# public build matrix links no gigastt/onnxruntime — the Voice page
# degrades to "unavailable" where the lib is missing.
#
# The ABI (~/gigastt/crates/gigastt-ffi/include/gigastt.h) is tiny:
# engine_new_with_pool_size, stream process_chunk/flush. All calls
# return NULL on error; segments come back as a JSON array
# [{"text": ..., "is_final": ...}]. We only ever feed whole clips —
# recordings are finished before recognition starts, so there is no
# separate Stream object: transcribe() opens, feeds, flushes and
# closes one streaming session internally. (transcribe_file itself is
# unusable here: it rejects absolute paths.)

require "json"
require "./dl"

module Kodkod
  module Voice
    module Gigastt
      class Error < Exception
      end

      SONAMES = {"libgigastt_ffi.so", "gigastt_ffi.dll"}

      # Engine/stream handles are opaque table ids on the C side.
      alias EnginePtr = Pointer(Void)
      alias StreamPtr = Pointer(Void)

      struct Segment
        getter text : String
        getter? final : Bool

        def initialize(@text, @final)
        end
      end

      # --- the dlsym'd ABI, resolved once -----------------------------
      alias NewWithPool = Proc(UInt8*, UInt64, EnginePtr)
      alias EngineFree  = Proc(EnginePtr, Void)
      alias StreamNew   = Proc(EnginePtr, StreamPtr)
      alias Process     = Proc(EnginePtr, StreamPtr, UInt8*, UInt64, UInt32, UInt8*)
      alias Flush       = Proc(EnginePtr, StreamPtr, UInt8*)
      alias StreamFree  = Proc(StreamPtr, Void)
      alias StringFree  = Proc(UInt8*, Void)

      record Fns,
        engine_new : NewWithPool,
        engine_free : EngineFree,
        stream_new : StreamNew,
        process : Process,
        flush : Flush,
        stream_free : StreamFree,
        string_free : StringFree

      @@handle : Void*? = Dl.open(SONAMES.to_a)
      @@fns : Fns?

      def self.available? : Bool
        !@@handle.nil?
      end

      # Resolve every symbol once; Error on a partial ABI.
      def self.fns! : Fns
        @@fns ||= begin
          raise Error.new("libgigastt_ffi недоступна") unless (h = @@handle)
          sym = ->(name : String) { Dl.sym(h, name) }
          ptr = ->(name : String) { (p = sym.call(name)) ?
            Pointer(Void).new(p.address) : nil }
          new_fn = ptr.call("gigastt_engine_new_with_pool_size")
          free_fn = ptr.call("gigastt_engine_free")
          stream_new = ptr.call("gigastt_stream_new")
          process = ptr.call("gigastt_stream_process_chunk")
          flush = ptr.call("gigastt_stream_flush")
          stream_free = ptr.call("gigastt_stream_free")
          string_free = ptr.call("gigastt_string_free")
          if new_fn && free_fn && stream_new && process && flush &&
             stream_free && string_free
            Fns.new(
              NewWithPool.new(new_fn, Pointer(Void).null),
              EngineFree.new(free_fn, Pointer(Void).null),
              StreamNew.new(stream_new, Pointer(Void).null),
              Process.new(process, Pointer(Void).null),
              Flush.new(flush, Pointer(Void).null),
              StreamFree.new(stream_free, Pointer(Void).null),
              StringFree.new(string_free, Pointer(Void).null))
          else
            raise Error.new("libgigastt_ffi неполна (нет символов ABI)")
          end
        end
      end

      # Copies a returned C string and frees the original. Every string
      # the ABI hands out must go through here (or leak).
      def self.take_string(ptr : UInt8*) : String?
        return nil if ptr.null?
        s = String.new(ptr)
        fns!.string_free.call(ptr)
        s
      end

      def self.parse_segments(json : String) : Array(Segment)
        segments = [] of Segment
        begin
          JSON.parse(json).as_a.each do |seg|
            text = seg["text"]?.try(&.as_s) || ""
            final = seg["is_final"]?.try(&.as_bool?) || false
            segments << Segment.new(text, final)
          end
          segments
        rescue JSON::Error
          [] of Segment
        end
      end

      # Joins segments the way perevodilka's pipeline does: a non-final
      # segment is a draft of the current phrase superseded by the next
      # — only finals (plus the tail, when nothing follows) survive.
      def self.join_segments(segments : Array(Segment)) : String
        segments.map_with_index do |seg, i|
          seg.final? || i == segments.size - 1 ? seg.text : nil
        end.compact.reject(&.empty?).join(" ")
      end

      # One loaded engine. pool_size = 1 (the small memory profile: one
      # inference triplet resident; the INT8 encoder is mmap-shared).
      class Engine
        getter ptr : EnginePtr

        @fns : Fns

        def initialize(model_dir : String, pool_size : UInt64 = 1_u64)
          fns = Gigastt.fns!
          @ptr = fns.engine_new.call(model_dir.to_unsafe, pool_size)
          raise Error.new("не удалось загрузить модель из #{model_dir}") if @ptr.null?
          @fns = fns
          @closed = false
        end

        # Whole-clip recognition through the streaming ABI: one feed of
        # the entire PCM + a flush of the decoder tail.
        def transcribe(pcm : Slice(Int16), sample_rate : Int32) : String
          fns = @fns
          stream = fns.stream_new.call(@ptr)
          raise Error.new("не удалось открыть сессию распознавания") if stream.null?
          begin
            bytes = pcm.to_unsafe.as(Pointer(UInt8))
            json = Gigastt.take_string(fns.process.call(
              @ptr, stream, bytes, (pcm.size * 2).to_u64, sample_rate.to_u32))
            raise Error.new("ошибка распознавания") unless json
            segments = Gigastt.parse_segments(json)
            tail = Gigastt.take_string(fns.flush.call(@ptr, stream))
            segments.concat(Gigastt.parse_segments(tail)) if tail
            Gigastt.join_segments(segments)
          ensure
            fns.stream_free.call(stream)
          end
        end

        def close : Nil
          if !@ptr.null? && !@closed
            @closed = true
            @fns.engine_free.call(@ptr)
            @ptr = Pointer(Void).null
          end
        end

        def finalize
          close
        end
      end
    end
  end
end
