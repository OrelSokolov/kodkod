# kodkod voice — a minimal SQLite3 binding over dlopen (no link-time
# dependency, no shard: the recording queue needs one table and a
# handful of prepared statements). One connection guarded by a mutex —
# the UI thread and the STT worker thread share it safely.
#
# Every sqlite3_* symbol resolves through dlsym at construction and
# lives in a Proc; the lib body below carries ONLY constants and
# opaque types (a `fun` there would demand the symbols at link time).

require "./dl"

lib LibSqlite3
  SQLITE_OK           =  0
  SQLITE_ROW          = 100
  SQLITE_DONE         = 101
  # sqlite3_open_v2 flags: READWRITE | CREATE
  OPEN_READWRITE      = 0x00000002
  OPEN_CREATE         = 0x00000004
  # sqlite3_column_type
  TYPE_NULL           = 5

  type Db   = Void*
  type Stmt = Void*
end

# sqlite3_bind_text destructor: SQLITE_TRANSIENT (make a private
# copy — a Pointer constant, so it lives outside the lib: lib
# constants must be literals).
SQLITE_TRANSIENT = Pointer(Void).new(-1)

module Kodkod
  module Voice
    class Sqlite
      class Error < Exception
      end

      SONAMES = {"libsqlite3.so", "libsqlite3.so.0", "sqlite3.dll", "sqlite3"}

      # Loaded once, kept for the process lifetime (dlclose never runs).
      @@handle : Void*? = Dl.open(SONAMES.to_a)

      def self.available? : Bool
        !@@handle.nil?
      end

      private def fn(type : T.class, name : String) : T forall T
        handle = @@handle.not_nil!
        ptr = Dl.sym(handle, name).not_nil!
        T.new(ptr, Pointer(Void).null)
      end

      getter db : LibSqlite3::Db

      # dlsym'd signatures, resolved once per connection (type ALIASES —
      # constants would not be usable as types).
      alias OpenV2       = Proc(UInt8*, LibSqlite3::Db*, Int32, UInt8*, Int32)
      alias CloseV2      = Proc(LibSqlite3::Db, Int32)
      alias Errmsg       = Proc(LibSqlite3::Db, UInt8*)
      alias BusyTimeout  = Proc(LibSqlite3::Db, Int32, Int32)
      alias Exec         = Proc(LibSqlite3::Db, UInt8*, Void*, Void*, UInt8**, Int32)
      alias PrepareV2    = Proc(LibSqlite3::Db, UInt8*, Int32, LibSqlite3::Stmt*, UInt8**, Int32)
      alias Step         = Proc(LibSqlite3::Stmt, Int32)
      alias Finalize     = Proc(LibSqlite3::Stmt, Int32)
      alias BindInt64    = Proc(LibSqlite3::Stmt, Int32, Int64, Int32)
      alias BindText     = Proc(LibSqlite3::Stmt, Int32, UInt8*, Int32, Void*, Int32)
      alias BindNull     = Proc(LibSqlite3::Stmt, Int32, Int32)
      alias ColumnType   = Proc(LibSqlite3::Stmt, Int32, Int32)
      alias ColumnInt64  = Proc(LibSqlite3::Stmt, Int32, Int64)
      alias ColumnText   = Proc(LibSqlite3::Stmt, Int32, UInt8*)
      alias ColumnBytes  = Proc(LibSqlite3::Stmt, Int32, Int32)
      alias LastInsertId = Proc(LibSqlite3::Db, Int64)
      alias Changes      = Proc(LibSqlite3::Db, Int32)

      @open_v2 : OpenV2
      @close_v2 : CloseV2
      @errmsg : Errmsg
      @busy_timeout : BusyTimeout
      @exec : Exec
      @prepare_v2 : PrepareV2
      @step : Step
      @finalize : Finalize
      @bind_int64 : BindInt64
      @bind_text : BindText
      @bind_null : BindNull
      @column_type : ColumnType
      @column_int64 : ColumnInt64
      @column_text : ColumnText
      @column_bytes : ColumnBytes
      @last_insert_rowid : LastInsertId
      @changes : Changes

      def initialize(path : String)
        raise Error.new("libsqlite3 недоступна") unless Sqlite.available?
        @open_v2 = fn(OpenV2, "sqlite3_open_v2")
        @close_v2 = fn(CloseV2, "sqlite3_close_v2")
        @errmsg = fn(Errmsg, "sqlite3_errmsg")
        @busy_timeout = fn(BusyTimeout, "sqlite3_busy_timeout")
        @exec = fn(Exec, "sqlite3_exec")
        @prepare_v2 = fn(PrepareV2, "sqlite3_prepare_v2")
        @step = fn(Step, "sqlite3_step")
        @finalize = fn(Finalize, "sqlite3_finalize")
        @bind_int64 = fn(BindInt64, "sqlite3_bind_int64")
        @bind_text = fn(BindText, "sqlite3_bind_text")
        @bind_null = fn(BindNull, "sqlite3_bind_null")
        @column_type = fn(ColumnType, "sqlite3_column_type")
        @column_int64 = fn(ColumnInt64, "sqlite3_column_int64")
        @column_text = fn(ColumnText, "sqlite3_column_text")
        @column_bytes = fn(ColumnBytes, "sqlite3_column_bytes")
        @last_insert_rowid = fn(LastInsertId, "sqlite3_last_insert_rowid")
        @changes = fn(Changes, "sqlite3_changes")

        db = Pointer(Void).null.as(LibSqlite3::Db)
        rc = @open_v2.call(path.to_unsafe,
          pointerof(db).as(LibSqlite3::Db*),
          LibSqlite3::OPEN_READWRITE | LibSqlite3::OPEN_CREATE, Pointer(UInt8).null)
        @db = db
        raise Error.new(errmsg) unless rc == LibSqlite3::SQLITE_OK
        @mutex = Thread::Mutex.new
        # The STT worker and the UI share this connection; a locked
        # moment (page read during a write) waits instead of failing.
        @busy_timeout.call(db, 5000)
      end

      def exec(sql : String) : Nil
        @mutex.synchronize do
          rc = @exec.call(@db, sql.to_unsafe, Pointer(Void).null, Pointer(Void).null, Pointer(Pointer(UInt8)).null)
          raise Error.new(errmsg) unless rc == LibSqlite3::SQLITE_OK
        end
      end

      # Prepare + run a statement to completion (no rows expected).
      # Values bind by 1-based index in call order; nil binds NULL.
      def run(sql : String, *values) : Nil
        @mutex.synchronize do
          stmt = prepare(sql)
          begin
            bind(stmt, values)
            check_step(step(stmt))
          ensure
            @finalize.call(stmt)
          end
        end
      end

      # Prepare + step once per row, yielding the statement for column
      # reads (see #int_at / #text_at). The block must not yield (no
      # IO) — sqlite calls are blocking C, safe on the caller's thread.
      def each(sql : String, *values, &) : Nil
        @mutex.synchronize do
          stmt = prepare(sql)
          begin
            bind(stmt, values)
            loop do
              rc = step(stmt)
              break if rc == LibSqlite3::SQLITE_DONE
              raise Error.new(errmsg) unless rc == LibSqlite3::SQLITE_ROW
              yield stmt
            end
          ensure
            @finalize.call(stmt)
          end
        end
      end

      # One row's first column as Int64, or nil when no row.
      def scalar_int(sql : String, *values) : Int64?
        result = nil
        each(sql, *values) { |stmt| result = @column_int64.call(stmt, 0) }
        result
      end

      def last_insert_id : Int64
        @mutex.synchronize { @last_insert_rowid.call(@db) }
      end

      # Run + report affected rows atomically under one lock pass —
      # the queue's claim CAS relies on it.
      def run_count(sql : String, *values) : Int32
        @mutex.synchronize do
          stmt = prepare(sql)
          begin
            bind(stmt, values)
            check_step(step(stmt))
            @changes.call(@db)
          ensure
            @finalize.call(stmt)
          end
        end
      end

      def close : Nil
        @mutex.synchronize { @close_v2.call(@db) }
      end

      # --- column readers for `each` blocks --------------------------

      def int_at(stmt : LibSqlite3::Stmt, idx : Int32 = 0) : Int64
        @column_int64.call(stmt, idx)
      end

      def text_at(stmt : LibSqlite3::Stmt, idx : Int32 = 0) : String?
        return nil if @column_type.call(stmt, idx) == LibSqlite3::TYPE_NULL
        ptr = @column_text.call(stmt, idx)
        return nil if ptr.null?
        String.new(ptr, @column_bytes.call(stmt, idx))
      end

      private def prepare(sql : String) : LibSqlite3::Stmt
        stmt = Pointer(Void).null.as(LibSqlite3::Stmt)
        tail = Pointer(UInt8).null
        rc = @prepare_v2.call(@db, sql.to_unsafe, -1,
          pointerof(stmt).as(LibSqlite3::Stmt*), pointerof(tail))
        raise Error.new(errmsg) unless rc == LibSqlite3::SQLITE_OK
        stmt
      end

      private def step(stmt : LibSqlite3::Stmt) : Int32
        @step.call(stmt)
      end

      private def check_step(rc : Int32) : Nil
        raise Error.new(errmsg) unless rc == LibSqlite3::SQLITE_ROW || rc == LibSqlite3::SQLITE_DONE
      end

      private def bind(stmt : LibSqlite3::Stmt, values) : Nil
        values.each_with_index do |v, i|
          idx = i + 1
          case v
          when Nil    then @bind_null.call(stmt, idx)
          when Int32  then @bind_int64.call(stmt, idx, v.to_i64)
          when Int64  then @bind_int64.call(stmt, idx, v)
          when String then @bind_text.call(stmt, idx, v.to_unsafe, v.bytesize, SQLITE_TRANSIENT)
          else raise Error.new("неbindable: #{v.class}")
          end
        end
      end

      private def errmsg : String
        msg = @errmsg.call(@db)
        msg.null? ? "sqlite error" : String.new(msg)
      end
    end
  end
end
