# kodkod — IndexQueue: the project indexer's jobs queue. The DEFAULT
# queue comes from a gitignore-aware walk of the workspace root: one
# job per top-level folder (plus one for the root's own files), so
# progress is observable per folder and no single job hogs the worker.
# Later, fs-change events (the EventBus's "index.fs") append small
# per-file/per-dir reindex jobs on the fly.
#
# The worker is a spawned fiber, not a thread: the Crystal scheduler
# is cooperative, and the loop Fiber.yields after every file so the
# UI keeps its frames. A `generation` counter invalidates a worker
# mid-run when the project folder changes or a rescan is ordered —
# the loop notices and exits without touching the fresh state.
#
# Events emitted (all on the worker's or the watcher's stack, all
# synchronous — see EventBus):
#   "index.updated"  a file's definitions swapped in (payload: path)
#   "queue.changed"  a job started or finished (payload: nil)

require "./event_bus"
require "./gitignore"
require "./symbol_extractor"
require "./symbol_index"

module Kodkod
  class IndexQueue
    # One indexing unit: every file under one folder (a :scan job,
    # built by the initial walk or a new-directory event) or a single
    # file (a :change job from an fs event).
    class Job
      getter folder : String    # absolute — the job's display unit
      getter files : Array(String) # absolute paths, in walk order
      getter reason : Symbol    # :scan | :change
      property state : Symbol = :pending # :pending | :running | :done
      property done : Int32 = 0

      def initialize(@folder : String, @files : Array(String),
                     @reason : Symbol = :scan)
      end

      def total : Int32
        @files.size
      end

      def scan? : Bool
        @reason == :scan
      end

      # Still owed work (pending or mid-run) — the fs-event dedup and
      # the Indexing page read this.
      def active? : Bool
        @state == :pending || @state == :running
      end
    end

    # Walk guards (mirrors QuickOpen's file walk).
    MAX_FILES = 20_000
    MAX_DEPTH = 24
    # Files over this size skip extraction — the regex pass is
    # synchronous; a vendored 20 MB minified blob is not worth it.
    MAX_FILE_BYTES = 1_000_000_i64

    getter jobs : Array(Job) = [] of Job
    getter root : String? = nil
    getter generation : Int32 = 0

    def initialize(@index : SymbolIndex, @bus : EventBus,
                   @lang_for : String -> String? = ->(path : String) {
                     nil.as(String?)
                   })
      @running = false
      @bus.on("index.fs") { |path| on_fs_event(path.to_s) }
      @bus.on("index.overflow") { rebuild }
    end

    # Point the queue at a new project root: drop everything, rebuild
    # the default per-folder jobs, wake a worker.
    def start(root : String) : Nil
      @generation += 1
      @root = root
      @jobs.clear
      @index.clear
      @jobs.concat(self.class.scan_jobs(root))
      @bus.emit("queue.changed")
      spawn_worker
    end

    # Rescan the same root (the Reindex button, an fs-event overflow).
    def rebuild : Nil
      start(@root.not_nil!) if @root
    end

    def busy? : Bool
      @running
    end

    def pending : Array(Job)
      @jobs.select(&.active?)
    end

    def current : Job?
      @jobs.find { |j| j.state == :running }
    end

    # --- the default queue: a gitignore-aware walk -------------------

    # One job per top-level folder (plus the root's loose files),
    # nested .gitignores honored — the queue the Indexing page shows.
    def self.scan_jobs(root : String) : Array(Job)
      jobs = [] of Job
      ignores = Gitignore.load(File.join(root, ".gitignore"))
      root_files = [] of String
      children = begin
        Dir.children(root).sort!
      rescue File::Error | IO::Error
        return jobs
      end
      children.each do |name|
        next if name == ".git" || name.starts_with?('.')
        path = File.join(root, name)
        next if ignores.try(&.ignores?(name, dir: File.directory?(path)))
        if File.symlink?(path)
          next
        elsif File.directory?(path)
          files = [] of String
          ignores = Gitignore.load(File.join(root, ".gitignore"))
          stack = [] of {String, Gitignore?}
          stack << {path, ignores}
          collect(path, stack, files, 0)
          jobs << Job.new(path, files) unless files.empty?
        elsif File.file?(path)
          root_files << path
        end
        break if root_files.size + jobs.sum(&.total) >= MAX_FILES
      end
      jobs.unshift(Job.new(root, root_files)) unless root_files.empty?
      jobs
    end

    # Recursive walk under `dir`, honoring the .gitignore stack
    # (deepest decisive match wins), hidden entries and symlink loops.
    def self.collect(dir : String,
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

    # Deepest .gitignore with an opinion wins; a deeper `!` negation
    # reads as "not ignored" only if the deeper file says so — the
    # basic-tier simplification (a negation cannot override a parent
    # ignore; real git can).
    private def self.ignored_by?(stack : Array({String, Gitignore?}),
                                 path : String, dir : Bool) : Bool
      stack.reverse_each do |base, gi|
        next unless gi
        rel = path.lchop(base).lchop('/')
        return true if gi.ignores?(rel, dir: dir)
      end
      false
    end

    # --- fs-event intake ----------------------------------------------

    # A watch event landed (file modified/created, or a directory
    # created — scanned so its files join the index). Deleted paths
    # drop out of the index directly.
    private def on_fs_event(path : String) : Nil
      root = @root || return
      return unless path.starts_with?(root)
      if File.directory?(path)
        files = [] of String
        ignores = Gitignore.load(File.join(root, ".gitignore"))
        stack = [] of {String, Gitignore?}
        stack << {path, ignores}
        self.class.collect(path, stack, files, 0)
        return if files.empty?
        unless @jobs.any? { |j| j.scan? && j.active? &&
                                j.folder == path }
          @jobs << Job.new(path, files)
          spawn_worker
        end
      elsif File.file?(path)
        unless @jobs.any? { |j| !j.scan? && j.active? &&
                                j.files == [path] }
          @jobs << Job.new(path, [path], :change)
          spawn_worker
        end
      else # gone: deleted or renamed away
        @index.remove(path)
        @bus.emit("index.updated", path)
      end
    end

    # --- the worker ----------------------------------------------------

    private def spawn_worker : Nil
      return if @running
      @running = true
      gen = @generation
      spawn(name: "kodkod-index") { run(gen) }
    end

    private def run(gen : Int32) : Nil
      while @generation == gen
        job = @jobs.find { |j| j.state == :pending } || break
        job.state = :running
        @bus.emit("queue.changed")
        job.files.each do |path|
          break unless @generation == gen
          index_file(path)
          job.done += 1
          @bus.emit("index.updated", path)
          Fiber.yield # keep the UI fiber fed
        end
        # A generation bump mid-job leaves it :running; the rescan's
        # start() cleared @jobs anyway, so only mark done in this gen.
        job.state = :done if @generation == gen
        @bus.emit("queue.changed")
      end
      @running = false
    end

    def index_file(path : String) : Nil
      lang = @lang_for.call(path)
      return unless SymbolExtractor.indexable?(lang)
      info = File.info?(path) || return
      return if info.size > MAX_FILE_BYTES
      text = begin
        File.read(path)
      rescue IO::Error | File::Error
        return
      end
      defs = SymbolExtractor.extract(text, lang).map do |h|
        SymbolIndex::Def.new(h.name, h.kind, path, h.line, h.col)
      end
      @index.replace(path, defs)
    end
  end
end
