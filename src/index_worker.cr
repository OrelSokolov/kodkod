# kodkod — IndexWorker: the indexing sidecar. The project walk and
# the regex/tokenizer extraction pass run in a SEPARATE PROCESS (the
# app re-execs itself with --index-worker): the Crystal scheduler is
# single threaded and Boehm-GC stop-the-world pauses land on the
# allocating thread, so a heavy project's indexing must not share a
# heap (or a thread) with the UI. The child speaks line-JSON over
# stdin/stdout:
#
#   parent → child : {"cmd":"folder","j":1,"p":"/abs","r":"/root"}
#                     {"cmd":"file","j":2,"p":"/abs"}
#   child → parent : {"j":1,"k":"total","n":42}     files found by the walk
#                     {"j":1,"k":"swap","p":"...","d":[["name","method",3,4],...]}
#                     {"j":1,"k":"done"}             the job's stream ended
#
# Backend is the queue-facing interface with two implementations:
# Client (the real subprocess) and Local (an in-process fiber that
# runs the same code — the spec suite, where re-exec would recurse
# into the suite, and the fallback when the binary cannot re-spawn).

require "json"
require "./gitignore"
require "./symbol_extractor"
require "./symbol_index"

module Kodkod
  module IndexWorker
    # Walk guards (mirrors QuickOpen's file walk). The budget is per
    # folder job, not per project — the per-folder split already
    # bounds any single walk.
    MAX_FILES = 20_000
    MAX_DEPTH = 24
    # Files over this size skip extraction — a vendored 20 MB
    # minified blob is not worth indexing.
    MAX_FILE_BYTES = 1_000_000_i64

    # One child→parent line, decoded.
    struct Record
      getter job : Int32
      getter kind : Symbol # :total | :swap | :done
      getter path : String?
      getter defs : Array(SymbolIndex::Def)
      getter count : Int32

      def initialize(@job, @kind, @path, @defs, @count)
      end

      def self.total(job : Int32, count : Int32) : self
        new(job, :total, nil, EMPTY_DEFS, count)
      end

      def self.swap(job : Int32, path : String,
                    defs : Array(SymbolIndex::Def)) : self
        new(job, :swap, path, defs, defs.size)
      end

      def self.done(job : Int32) : self
        new(job, :done, nil, EMPTY_DEFS, 0)
      end

      EMPTY_DEFS = [] of SymbolIndex::Def

      def total? : Bool
        @kind == :total
      end

      def swap? : Bool
        @kind == :swap
      end

      def done? : Bool
        @kind == :done
      end
    end

    # --- the wire codec ------------------------------------------------

    def self.encode(rec : Record) : String
      String.build do |io|
        JSON.build(io) do |json|
          json.object do
            json.field "j", rec.job
            json.field "k", rec.kind.to_s
            case rec.kind
            when :total
              json.field "n", rec.count
            when :swap
              json.field "p", rec.path
              json.field "d" do
                json.array do
                  rec.defs.each do |d|
                    json.array do
                      json.string d.name
                      json.string d.kind.to_s
                      json.number d.line
                      json.number d.col
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # Wire name → Def kind (String has no #to_sym in Crystal).
    KIND_BY_NAME = {
      "method"   => :method,
      "class"    => :class,
      "module"   => :module,
      "macro"    => :macro,
      "type"     => :type,
      "function" => :function,
      "constant" => :constant,
    } of String => Symbol

    def self.decode(line : String) : Record?
      obj = JSON.parse(line).as_h
      job = obj["j"].as_i.to_i32
      case obj["k"].as_s
      when "total" then Record.total(job, obj["n"].as_i.to_i32)
      when "swap"
        path = obj["p"].as_s
        defs = obj["d"].as_a.map do |a|
          kind = KIND_BY_NAME[a[1].as_s]? || return nil
          SymbolIndex::Def.new(a[0].as_s, kind, path,
            a[2].as_i.to_i32, a[3].as_i.to_i32)
        end
        Record.swap(job, path, defs)
      when "done" then Record.done(job)
      end
    rescue JSON::Error | KeyError | TypeCastError
      nil # a garbled line is dropped, never fatal
    end

    # --- the child loop (also the Local backend's engine) -------------

    # Serve commands from `input` until EOF. Runs in the sidecar
    # process (see kodkod.cr's --index-worker branch); blocks are its
    # own — no cooperative slicing needed here.
    def self.run(input : IO, output : IO,
                 lang_for : String -> String?) : Nil
      input.each_line do |line|
        next if line.blank?
        begin
          cmd = JSON.parse(line).as_h
          job = cmd["j"].as_i.to_i32
          case cmd["cmd"].as_s
          when "folder"
            walk_folder(cmd["p"].as_s, cmd["r"].as_s, job,
              output, lang_for)
          when "file"
            emit(output, Record.swap(job, cmd["p"].as_s,
              extract_defs(cmd["p"].as_s, lang_for)))
            emit(output, Record.done(job))
          end
        rescue JSON::Error | KeyError
          # a malformed command is skipped, the parent resends
        end
      end
    rescue IO::Error
      # the parent went away — the pipe is the process lifetime
    end

    private def self.emit(output : IO, rec : Record) : Nil
      output.puts encode(rec)
      output.flush
    end

    # Walk one folder (gitignore-aware, root's .gitignore honored)
    # and stream per-file records bookended by :total and :done.
    def self.walk_folder(folder : String, root : String, job : Int32,
                         output : IO, lang_for : String -> String?) : Nil
      files = walk(folder, root)
      emit(output, Record.total(job, files.size))
      files.each do |path|
        emit(output, Record.swap(job, path, extract_defs(path, lang_for)))
      end
      emit(output, Record.done(job))
    end

    # The recursive gitignore-aware walk under `folder` (nested
    # .gitignores honored — deepest decisive match wins, hidden
    # entries and symlink loops skipped).
    def self.walk(folder : String, root : String) : Array(String)
      files = [] of String
      stack = [] of {String, Gitignore?}
      stack << {folder, Gitignore.load(File.join(root, ".gitignore"))}
      collect(folder, stack, files, 0)
      files
    end

    private def self.collect(dir : String,
                             stack : Array({String, Gitignore?}),
                             acc : Array(String), depth : Int32) : Nil
      return if depth >= MAX_DEPTH || acc.size >= MAX_FILES
      nested = Gitignore.load(File.join(dir, ".gitignore"))
      here = [{dir, nested}] + stack
      Dir.each_child(dir) do |name|
        next if name == ".git" || name.starts_with?('.')
        path = File.join(dir, name)
        next if File.symlink?(path)
        is_dir = File.directory?(path)
        next if ignored_by?(here, path, is_dir)
        if is_dir
          collect(path, here, acc, depth + 1)
        elsif File.file?(path)
          acc << path
        end
        return if acc.size >= MAX_FILES
      end
    rescue File::Error | IO::Error
      # An unreadable subtree is skipped, not fatal.
    end

    private def self.ignored_by?(stack : Array({String, Gitignore?}),
                                 path : String, dir : Bool) : Bool
      stack.reverse_each do |base, gi|
        next unless gi
        rel = path.lchop(base).lchop('/')
        return true if gi.ignores?(rel, dir: dir)
      end
      false
    end

    # One file's definitions (empty when not indexable / unreadable /
    # over the size cap).
    def self.extract_defs(path : String,
                          lang_for : String -> String?) : Array(SymbolIndex::Def)
      lang = lang_for.call(path)
      return Record::EMPTY_DEFS unless SymbolExtractor.indexable?(lang)
      info = File.info?(path) || return Record::EMPTY_DEFS
      return Record::EMPTY_DEFS if info.size > MAX_FILE_BYTES
      text = begin
        File.read(path)
      rescue IO::Error | File::Error
        return Record::EMPTY_DEFS
      end
      SymbolExtractor.extract(text, lang).map do |h|
        SymbolIndex::Def.new(h.name, h.kind, path, h.line, h.col)
      end
    end

    # --- the parent-facing backends ------------------------------------

    # What IndexQueue drives: commands go out, Records come back on a
    # channel (one :done per job, then the next job may be sent).
    abstract class Backend
      getter records : Channel(Record)

      def initialize
        @records = Channel(Record).new(64)
      end

      abstract def folder(job : Int32, folder : String, root : String) : Nil
      abstract def file(job : Int32, path : String) : Nil

      # Abort in-flight work and drop pending records (a generation
      # bump): the channel closes, so a queue fiber blocked on
      # receive wakes with Channel::ClosedError.
      abstract def kill : Nil
    end

    # The sidecar client: spawns the app binary with --index-worker
    # (lazily, once, restarting it if it died), keeps one reader
    # fiber pumping stdout lines into the records channel.
    class Client < Backend
      @proc : Process? = nil
      @broken = false

      def initialize(@exe : String, @args : Array(String))
        super()
      end

      def folder(job : Int32, folder : String, root : String) : Nil
        send({"cmd" => "folder", "j" => job, "p" => folder, "r" => root})
      end

      def file(job : Int32, path : String) : Nil
        send({"cmd" => "file", "j" => job, "p" => path})
      end

      def kill : Nil
        if (p = @proc)
          @proc = nil
          p.input.close rescue IO::Error
          p.terminate rescue IO::Error
        end
        @records.close
      end

      private def send(cmd : Hash(String, String | Int32)) : Nil
        return if @broken
        if (p = ensure_proc)
          begin
            p.input.puts cmd.to_json
            p.input.flush
          rescue IO::Error
            job = cmd["j"].as(Int32)
            @records.send(Record.done(job)) # unblock the waiter
            @records.close
          end
        else
          # The sidecar cannot be spawned at all — finish the job
          # empty rather than hanging the queue.
          job = cmd["j"].as(Int32)
          @records.send(Record.done(job))
          @records.close
        end
      end

      private def ensure_proc : Process?
        if (p = @proc) && !p.terminated?
          return p
        end
        begin
          p = Process.new(@exe, @args,
            input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
            error: Process::Redirect::Inherit)
        rescue ex : IO::Error | File::Error
          STDERR.puts "kodkod: index sidecar failed to start: #{ex.message}"
          @broken = true
          return nil
        end
        @proc = p
        spawn(name: "kodkod-index-read") { pump(p) }
        p
      end

      private def pump(p : Process) : Nil
        loop do
          line = begin
            p.output.read_line
          rescue IO::Error
            break
          end
          next if line.blank?
          if (rec = IndexWorker.decode(line))
            @records.send(rec) rescue break # closed by kill
          end
        end
        @records.close
      end
    end

    # The in-process fallback: same walk/extract code on a spawned
    # fiber, yielding between files. Used by the spec suite (re-exec
    # would recurse into it) and whenever the sidecar can't run.
    class Local < Backend
      def initialize(@lang_for : String -> String?)
        super()
        @killed = false
      end

      def folder(job : Int32, folder : String, root : String) : Nil
        spawn(name: "kodkod-index-local") { run_folder(job, folder, root) }
      end

      def file(job : Int32, path : String) : Nil
        spawn(name: "kodkod-index-local") { run_file(job, path) }
      end

      def kill : Nil
        @killed = true
        @records.close
      end

      private def run_folder(job : Int32, folder : String, root : String) : Nil
        files = IndexWorker.walk(folder, root)
        return unless send_record(Record.total(job, files.size))
        files.each do |path|
          return if @killed
          rec = Record.swap(job, path,
            IndexWorker.extract_defs(path, @lang_for))
          return unless send_record(rec)
          Fiber.yield
        end
        send_record(Record.done(job))
      end

      private def run_file(job : Int32, path : String) : Nil
        return unless send_record(Record.swap(job, path,
          IndexWorker.extract_defs(path, @lang_for)))
        send_record(Record.done(job))
      end

      # false once killed/closed — the caller stops feeding records.
      private def send_record(rec : Record) : Bool
        @records.send(rec)
        true
      rescue Channel::ClosedError
        false
      end
    end
  end
end
