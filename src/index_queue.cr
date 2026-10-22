# kodkod — IndexQueue: the project indexer's jobs queue. The DEFAULT
# queue comes from the workspace root's own directory listing only
# (one readdir — cheap): one job per top-level folder (plus one for
# the root's loose files). The per-folder RECURSIVE walks run on the
# worker fiber, never on the caller's — enumerating a heavy project
# must not block the UI fiber that called start(). fs-change events
# (the EventBus's "index.fs") append debounced per-file reindex jobs
# (a save storm owes one job per file) and lazy walk jobs for new
# directories.
#
# The worker is a spawned fiber, not a thread: the Crystal scheduler
# is cooperative, so the loop budgets its slices by the CLOCK (SLICE)
# rather than per file — one oversized file cannot eat a frame — and
# SymbolExtractor.extract checkpoints every 512 lines through the
# same budget. Among pending jobs, the one covering the active
# editor's file (the @prio_for proc) jumps the queue. A `generation`
# counter invalidates a worker mid-run when the project folder
# changes or a rescan is ordered — the loop notices and exits without
# touching the fresh state.
#
# Events emitted (all on the worker's or the watcher's stack, all
# synchronous — see EventBus):
#   "index.updated"  a file's definitions swapped in (payload: path)
#   "queue.changed"  a job started, finished or was appended (payload: nil)

require "./event_bus"
require "./gitignore"
require "./symbol_extractor"
require "./symbol_index"

module Kodkod
  class IndexQueue
    # One indexing unit: every file under one folder (a :scan job,
    # walked lazily by the worker) or a single file (a :change job
    # from a debounced fs event).
    class Job
      getter folder : String          # absolute — the job's display unit
      property files : Array(String)  # absolute paths, filled by the walk
      getter reason : Symbol          # :scan | :change
      property state : Symbol = :pending # :pending | :running | :done
      property done : Int32 = 0
      property? walked : Bool         # false until the worker walked it

      def initialize(@folder : String, @files : Array(String),
                     @reason : Symbol = :scan, @walked : Bool = true)
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
    # The worker's cooperative time budget: after this long without a
    # yield the scheduler gets control back so the UI fiber keeps its
    # frames, whatever the file sizes in flight.
    SLICE = 8.milliseconds
    # fs events sit in @dirty this long before becoming :change jobs —
    # a save storm or a checkout collapses into one job per file.
    DEBOUNCE = 300.milliseconds

    getter jobs : Array(Job) = [] of Job
    getter root : String? = nil
    getter generation : Int32 = 0

    def initialize(@index : SymbolIndex, @bus : EventBus,
                   @lang_for : String -> String? = ->(path : String) {
                     nil.as(String?)
                   },
                   @prio_for : -> String? = ->{ nil.as(String?) })
      @running = false
      @remaining = MAX_FILES
      @dirty = [] of String
      @debounce_armed = false
      @slice_end = Time.instant
      @bus.on("index.fs") { |path| on_fs_event(path.to_s) }
      @bus.on("index.overflow") { rebuild }
    end

    # Point the queue at a new project root: drop everything, build
    # the lazy per-folder jobs from the root's own listing, wake a
    # worker. The recursive walks happen on the worker, not here.
    def start(root : String) : Nil
      @generation += 1
      @root = root
      @jobs.clear
      @index.clear
      @dirty.clear
      @debounce_armed = false
      @remaining = MAX_FILES
      @jobs.concat(self.class.initial_jobs(root))
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

    # --- the default queue: the root's own listing --------------------

    # One lazy :scan job per non-ignored top-level folder (plus the
    # root's loose files, known immediately) — the worker does the
    # recursive gitignore-aware walking when the job runs.
    def self.initial_jobs(root : String) : Array(Job)
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
          jobs << Job.new(path, [] of String, walked: false)
        elsif File.file?(path)
          root_files << path
        end
      end
      jobs.unshift(Job.new(root, root_files)) unless root_files.empty?
      jobs
    end

    # Recursive walk under `dir`, honoring the .gitignore stack
    # (deepest decisive match wins), hidden entries and symlink loops.
    # Runs on the worker fiber and time-slices like everything else;
    # the MAX_FILES budget is shared across all of a root's jobs.
    private def collect(dir : String,
                        stack : Array({String, Gitignore?}),
                        acc : Array(String), depth : Int32) : Nil
      return if depth >= MAX_DEPTH || @remaining <= 0
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
          @remaining -= 1
        end
        return if @remaining <= 0
        slice_yield
      end
    rescue File::Error | IO::Error
      # An unreadable subtree is skipped, not fatal.
    end

    # Deepest .gitignore with an opinion wins; a deeper `!` negation
    # reads as "not ignored" only if the deeper file says so — the
    # basic-tier simplification (a negation cannot override a parent
    # ignore; real git can).
    private def ignored_by?(stack : Array({String, Gitignore?}),
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
    # created — its walk job joins the queue). File events are
    # DEBOUNCED: the path lands in @dirty and becomes one :change job
    # when the burst settles. Deleted paths drop out of the index
    # directly.
    private def on_fs_event(path : String) : Nil
      root = @root || return
      return unless path.starts_with?(root)
      if File.directory?(path)
        unless @jobs.any? { |j| j.scan? && j.active? &&
                                j.folder == path }
          @jobs << Job.new(path, [] of String, walked: false)
          @bus.emit("queue.changed")
          spawn_worker
        end
      elsif File.file?(path)
        return if @dirty.includes?(path) ||
                  @jobs.any? { |j| !j.scan? && j.active? &&
                                    j.files.size == 1 && j.files.first == path }
        @dirty << path
        arm_debounce
      else # gone: deleted or renamed away
        @index.remove(path)
        @bus.emit("index.updated", path)
      end
    end

    # One timer fiber per burst: when it fires, the whole @dirty set
    # becomes :change jobs at once (see flush).
    private def arm_debounce : Nil
      return if @debounce_armed
      @debounce_armed = true
      gen = @generation
      spawn(name: "kodkod-index-flush") do
        sleep DEBOUNCE
        flush if @generation == gen
      end
    end

    # Turn the debounced dirty set into :change jobs (the timer's
    # callback; safe to call any time — the tests pump it directly).
    def flush : Nil
      @debounce_armed = false
      paths, @dirty = @dirty, [] of String
      return if paths.empty? || @root.nil?
      paths.each do |p|
        next if @jobs.any? { |j| !j.scan? && j.active? &&
                                j.files.size == 1 && j.files.first == p }
        @jobs << Job.new(p, [p], :change)
      end
      @bus.emit("queue.changed")
      spawn_worker
    end

    # --- the worker ----------------------------------------------------

    private def spawn_worker : Nil
      return if @running
      @running = true
      gen = @generation
      spawn(name: "kodkod-index") { run(gen) }
    end

    private def run(gen : Int32) : Nil
      reset_slice
      while @generation == gen
        job = next_job || break
        job.state = :running
        @bus.emit("queue.changed")
        walk(job) unless job.walked?
        job.files.each do |path|
          break unless @generation == gen
          index_file(path)
          job.done += 1
          @bus.emit("index.updated", path)
          slice_yield
        end
        # A generation bump mid-job leaves it :running; the rescan's
        # start() cleared @jobs anyway, so only mark done in this gen.
        job.state = :done if @generation == gen
        @bus.emit("queue.changed")
      end
      @running = false
    end

    # The next job to run: a pending job covering the active editor's
    # file jumps the queue (a :change for it first, then its :scan
    # folder), else insertion order.
    private def next_job : Job?
      if (prio = @prio_for.call)
        hit = @jobs.find { |j| j.state == :pending && !j.scan? &&
                               j.files.size == 1 && j.files.first == prio } ||
              @jobs.find { |j| j.state == :pending && j.scan? &&
                               prio.starts_with?(j.folder) }
        return hit if hit
      end
      @jobs.find { |j| j.state == :pending }
    end

    # Fill a lazy scan job's file list: the recursive walk, on the
    # worker fiber, time-sliced like everything else.
    private def walk(job : Job) : Nil
      root = @root.not_nil!
      files = [] of String
      stack = [] of {String, Gitignore?}
      stack << {job.folder, Gitignore.load(File.join(root, ".gitignore"))}
      collect(job.folder, stack, files, 0)
      job.files = files
      job.walked = true
      @bus.emit("queue.changed") # the Indexing page's totals wake up
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
      defs = SymbolExtractor.extract(text, lang) { slice_yield }.map do |h|
        SymbolIndex::Def.new(h.name, h.kind, path, h.line, h.col)
      end
      @index.replace(path, defs)
    end

    # --- cooperative time budget ---------------------------------------

    private def reset_slice : Nil
      @slice_end = Time.instant + SLICE
    end

    # Yield to the scheduler once this slice's budget is spent — the
    # UI fiber gets its frame, then a fresh budget starts.
    private def slice_yield : Nil
      return if Time.instant < @slice_end
      Fiber.yield
      @slice_end = Time.instant + SLICE
    end
  end
end
