# kodkod voice — the recording queue store: SQLite (src/voice/sqlite.cr),
# one `recordings` table keyed by project folder. Status flows
# queued → running → done/failed; retry puts a row back to queued.
# Crash recovery: any `running` row at open time goes back to queued.

require "./sqlite"

module Kodkod
  module Voice
    class DB
      record Recording,
        id : Int64,
        project : String,
        wav : String,
        duration_ms : Int64,
        status : String,
        transcript : String?,
        error : String?,
        engine : String?,
        created_at : Int64

      SCHEMA = <<-SQL
        CREATE TABLE IF NOT EXISTS recordings(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project TEXT NOT NULL,
          wav TEXT NOT NULL,
          duration_ms INTEGER NOT NULL,
          status TEXT NOT NULL CHECK(status IN ('queued','running','done','failed')),
          transcript TEXT,
          error TEXT,
          engine TEXT,
          created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS recordings_project
          ON recordings(project, id);
      SQL

      def initialize(@sqlite : Sqlite)
        @sqlite.exec(SCHEMA)
        # A previous process may have died mid-transcription: hand its
        # row back to the queue (the claim CAS makes double-run safe).
        @sqlite.run("UPDATE recordings SET status = 'queued' " \
                    "WHERE status = 'running'")
      end

      def self.open(dir : String) : DB
        Dir.mkdir_p(dir)
        new(Sqlite.new(File.join(dir, "voice.sqlite3")))
      end

      def insert(project : String, wav : String, duration_ms : Int64) : Int64
        @sqlite.run(
          "INSERT INTO recordings(project, wav, duration_ms, status, created_at) " \
          "VALUES(?, ?, ?, 'queued', ?)",
          project, wav, duration_ms, Time.utc.to_unix)
        @sqlite.last_insert_id
      end

      # Claim the oldest queued row (→ running) for the worker. The
      # UPDATE .. WHERE status = 'queued' + changes-count check is the
      # CAS: exactly one claimer wins a row.
      def claim_next : Recording?
        id = @sqlite.scalar_int(
          "SELECT id FROM recordings WHERE status = 'queued' " \
          "ORDER BY id LIMIT 1")
        return nil unless id
        n = @sqlite.run_count(
          "UPDATE recordings SET status = 'running' WHERE id = ? AND status = 'queued'",
          id)
        return nil unless n > 0
        get(id)
      end

      def get(id : Int64) : Recording?
        row = nil
        @sqlite.each("SELECT * FROM recordings WHERE id = ?", id) do |stmt|
          row = Recording.new(
            @sqlite.int_at(stmt, 0), @sqlite.text_at(stmt, 1).to_s,
            @sqlite.text_at(stmt, 2).to_s, @sqlite.int_at(stmt, 3),
            @sqlite.text_at(stmt, 4).to_s, @sqlite.text_at(stmt, 5),
            @sqlite.text_at(stmt, 6), @sqlite.text_at(stmt, 7),
            @sqlite.int_at(stmt, 8))
        end
        row
      end

      def set_result(id : Int64, status : String, transcript : String?,
                     error : String?, engine : String?) : Nil
        @sqlite.run(
          "UPDATE recordings SET status = ?, transcript = ?, error = ?, engine = ? " \
          "WHERE id = ?", status, transcript, error, engine, id)
      end

      # Re-run a finished/failed transcription (the Voice page's retry).
      def requeue(id : Int64) : Bool
        @sqlite.run_count(
          "UPDATE recordings SET status = 'queued', error = NULL " \
          "WHERE id = ? AND status != 'running'", id) > 0
      end

      def requeue_all : Nil
        @sqlite.run("UPDATE recordings SET status = 'queued', error = NULL " \
                    "WHERE status != 'queued'")
      end

      def delete(id : Int64) : Nil
        @sqlite.run("DELETE FROM recordings WHERE id = ?", id)
      end

      # Newest first; nil project = every project (the page's filter).
      def list(project : String? = nil, limit : Int32 = 200) : Array(Recording)
        rows = [] of Recording
        if project
          @sqlite.each("SELECT * FROM recordings WHERE project = ? " \
                       "ORDER BY id DESC LIMIT ?", project, limit) { |s| rows << parse(s) }
        else
          @sqlite.each("SELECT * FROM recordings ORDER BY id DESC LIMIT ?",
                       limit) { |s| rows << parse(s) }
        end
        rows
      end

      def queued_count : Int32
        @sqlite.scalar_int(
          "SELECT COUNT(*) FROM recordings WHERE status IN ('queued','running')").try(&.to_i32) || 0
      end

      def close : Nil
        @sqlite.close
      end

      private def parse(stmt : LibSqlite3::Stmt) : Recording
        Recording.new(
          @sqlite.int_at(stmt, 0), @sqlite.text_at(stmt, 1).to_s,
          @sqlite.text_at(stmt, 2).to_s, @sqlite.int_at(stmt, 3),
          @sqlite.text_at(stmt, 4).to_s, @sqlite.text_at(stmt, 5),
          @sqlite.text_at(stmt, 6), @sqlite.text_at(stmt, 7),
          @sqlite.int_at(stmt, 8))
      end
    end
  end
end
