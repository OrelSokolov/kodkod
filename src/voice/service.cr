# kodkod voice — the orchestrator: recording → WAV → the SQLite queue
# → the STT worker thread → finished events for the UI.
#
# Threading model (mirrors perevodilka): blocking C work (inference)
# runs on one RAW worker thread — the Crystal scheduler must never be
# stalled. The UI thread never touches the engine; it polls snapshots
# each frame (the app pumps request_repaint while #active?) and drains
# #take_finished for the insert-at-cursor handoff. The worker polls
# the queue table — a 150 ms index count is pocket change next to the
# seconds an inference takes, and no condvar dance is needed.

require "./db"
require "./model_store"
require "./wav"
require "./gigastt"
require "./recorder"

module Kodkod
  module Voice
    # One recognition engine. GigaAM today; the seam a future whisper
    # implementation plugs into.
    abstract class Transcriber
      abstract def name : String
      abstract def transcribe(pcm : Slice(Int16), sample_rate : Int32) : String
    end

    class GigasttTranscriber < Transcriber
      def initialize(model_dir : String)
        @engine = Gigastt::Engine.new(model_dir, pool_size: 1_u64)
      end

      def name : String
        "gigaam-rnnt"
      end

      def transcribe(pcm : Slice(Int16), sample_rate : Int32) : String
        @engine.transcribe(pcm, sample_rate)
      end
    end

    class Service
      class Error < Exception
      end

  # Insertion preprocessing: a raw transcript is one long line,
      # unreadable in an editor — word-wrap to `width` chars (a longer
      # word stays whole; existing \n paragraphs are kept), and ALWAYS
      # end with a newline so the next edit starts on a fresh line.
      def self.wrap_text(text : String, width : Int32 = 120) : String
        return "" if text.blank?
        lines = [] of String
        text.split('\n').each do |para|
          line = ""
          para.split(' ').each do |word|
            candidate = line.empty? ? word : "#{line} #{word}"
            if candidate.size > width && !line.empty?
              lines << line
              line = word
            else
              line = candidate
            end
          end
          lines << line unless line.empty?
        end
        wrapped = lines.join('\n')
        wrapped.ends_with?('\n') ? wrapped : "#{wrapped}\n"
      end

      # A finished queue row, drained by the UI frame.
      record Finished, id : Int64, transcript : String, ok : Bool

      RECORDER_RATE = 16_000

      getter models : ModelStore
      getter db : DB
      getter? active_recording : Bool = false
      getter record_error : String? = nil

      @engine_state : Symbol = :idle # :idle :loading :ready :failed
      @engine_error : String? = nil
      @transcriber : Transcriber? = nil
      @recorder : Recorder? = nil
      @record_project = ""
      @record_fid : String? = nil
      @auto_insert = {} of Int64 => String
      @finished = [] of Finished
      @mutex = Thread::Mutex.new
      @stopping = false
      @worker : Thread? = nil
      @has_engine_lib : Bool = false

      def initialize(data_dir : String,
                     factory : (-> Transcriber?)? = nil)
        @db = DB.open(data_dir)
        @recdir = File.join(data_dir, "recordings")
        Dir.mkdir_p(@recdir)
        @models = ModelStore.new(File.join(data_dir, "models"))
        @factory = factory || ->() : Transcriber? {
          return nil unless Gigastt.available?
          GigasttTranscriber.new(@models.dir)
        }
        @has_engine_lib = factory ? true : Gigastt.available?
      end

      # --- model/engine status (UI snapshot) --------------------------
      #
      # :no_lib / :no_models / :downloading are derived on the spot;
      # :idle/:loading/:ready/:failed come from the worker thread.
      def engine_status : {Symbol, String?}
        return {:no_lib, nil} unless @has_engine_lib
        return {:downloading, nil} if models.downloading?
        return {:no_models, nil} unless models.complete?
        @mutex.synchronize { {@engine_state, @engine_error} }
      end

      # The model bundle is there but the engine never loaded yet —
      # preload starts the worker's load path on demand.
      def preload : Nil
        start_worker
        @want_preload = true
      end

      # Reset a failed engine state and ask the worker to try again.
      def retry_engine : Nil
        @mutex.synchronize do
          if @engine_state == :failed
            @engine_state = :idle
            @engine_error = nil
          end
        end
        preload
      end

      getter? want_preload : Bool = false

      # Anything animating → the app keeps repainting while true.
      def active? : Bool
        recording? || models.downloading? || @mutex.synchronize {
          @engine_state == :loading
        } || @db.queued_count > 0
      end

      def working? : Bool
        @mutex.synchronize { @engine_state == :loading } || @db.queued_count > 0
      end

      def queued_count : Int32
        @db.queued_count
      end

      # The recognition engine's name — what the voice strip shows.
      # Before the first load it names the engine the default factory
      # WILL build (the only wired one today).
      def engine_name : String
        @mutex.synchronize { @transcriber.try(&.name) } || "gigaam-rnnt"
      end

      # --- recording ----------------------------------------------------

      def recording? : Bool
        !@recorder.nil?
      end

      def elapsed : Float64
        @recorder.try(&.elapsed) || 0.0
      end

      # `focus_id` — the editor tab the recording was invoked in; when
      # the transcript is ready the app inserts it there (at whatever
      # the caret position is BY THEN), unless the tab was closed.
      def start_recording(project : String, focus_id : String?) : Bool
        return false if recording?
        rec = Recorder.new(RECORDER_RATE)
        unless rec.start
          @record_error = rec.error
          return false
        end
        @recorder = rec
        @record_project = project
        @record_fid = focus_id
        @record_error = nil
        start_worker
        true
      end

      def stop_recording : Nil
        rec = @recorder
        return unless rec
        @recorder = nil
        pcm = rec.stop
        if pcm.empty?
          @record_error = "ничего не записано"
          return
        end
        ingest(pcm, rec.sample_rate, @record_project, @record_fid)
      end

      # Test/internal entry: a finished capture entering the queue.
      def ingest(pcm : Slice(Int16), sample_rate : Int32, project : String,
                 focus_id : String?) : Nil
        name = "#{Time.local.to_unix_ms}-#{Random.new.hex(4)}.wav"
        Wav.write(File.join(@recdir, name), pcm, sample_rate)
        duration_ms = pcm.size.to_i64 * 1000 // sample_rate
        id = @db.insert(project, name, duration_ms)
        if fid = focus_id
          @mutex.synchronize { @auto_insert[id] = fid }
        end
        start_worker
      end

      # The doc that owes this recording an auto-insert (consumed once).
      def auto_insert_target(id : Int64) : String?
        @mutex.synchronize { @auto_insert.delete(id) }
      end

      # --- queue actions (page buttons) ---------------------------------

      def retranscribe(id : Int64) : Nil
        @db.requeue(id)
        start_worker
      end

      def retranscribe_all : Nil
        @db.requeue_all
        start_worker
      end

      def delete(id : Int64) : Nil
        if (row = @db.get(id)) && (wav = row.wav)
          File.delete?(File.join(@recdir, wav))
        end
        @db.delete(id)
        @mutex.synchronize { @auto_insert.delete(id) }
      end

      def list(project : String?) : Array(DB::Recording)
        @db.list(project)
      end

      def wav_path(row : DB::Recording) : String
        File.join(@recdir, row.wav)
      end

      # Finished rows for the UI frame (drained).
      def take_finished : Array(Finished)
        @mutex.synchronize do
          out = @finished
          @finished = [] of Finished
          out
        end
      end

      def close : Nil
        @stopping = true
        @worker.try(&.join)
        @worker = nil
        @db.close
      end

      # --- the worker thread --------------------------------------------

      private def start_worker : Nil
        return if @worker
        @worker = Thread.new { worker_loop }
      end

      private def worker_loop : Nil
        until @stopping
          begin
            if @want_preload
              ensure_transcriber
              @want_preload = false
            end
            process_next if @db.queued_count > 0
          rescue e : Exception
            # Never let the loop die: the error surfaces on the row /
            # the engine status, the queue stays serviceable.
            @mutex.synchronize do
              @engine_state = :failed
              @engine_error = e.message
            end
          end
          LibUsleep.usleep(150_000)
        end
      end

      private def process_next : Nil
        row = @db.claim_next
        return unless row
        transcriber = ensure_transcriber
        unless transcriber
          error = @mutex.synchronize { @engine_error } ||
                  "движок распознавания недоступен"
          @db.set_result(row.id, "failed", nil, error, nil)
          push_finished(row.id, "", false)
          return
        end
        begin
          pcm, rate = Wav.read(File.join(@recdir, row.wav))
          text = transcriber.not_nil!.transcribe(pcm, rate)
          if text.empty?
            @db.set_result(row.id, "failed", nil, "речь не распознана",
                           transcriber.not_nil!.name)
            push_finished(row.id, "", false)
          else
            @db.set_result(row.id, "done", text, nil,
                           transcriber.not_nil!.name)
            push_finished(row.id, text, true)
          end
        rescue e : Exception
          @db.set_result(row.id, "failed", nil, e.message.to_s,
                         transcriber.try(&.name))
          push_finished(row.id, "", false)
        end
      end

      # Loads the engine once; nil (with @engine_error set) when the
      # factory can't produce one. The engine stays resident.
      private def ensure_transcriber : Transcriber?
        return @transcriber if (t = @transcriber)
        return nil if @mutex.synchronize { @engine_state == :failed }
        @mutex.synchronize { @engine_state = :loading }
        begin
          t = @factory.call
          if t.nil?
            @mutex.synchronize do
              @engine_state = :failed
              @engine_error = "движок распознавания недоступен " \
                              "(нет libgigastt_ffi)"
            end
            return nil
          end
          @transcriber = t
          @mutex.synchronize { @engine_state = :ready }
          t
        rescue e : Exception
          @mutex.synchronize do
            @engine_state = :failed
            @engine_error = e.message
          end
          nil
        end
      end

      private def push_finished(id : Int64, transcript : String, ok : Bool) : Nil
        @mutex.synchronize { @finished << Finished.new(id, transcript, ok) }
      end
    end
  end
end
