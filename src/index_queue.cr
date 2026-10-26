# kodkod — IndexQueue: the project indexer's job dispatcher. The
# queue itself stays CHEAP on purpose — jobs, dedup, debounce,
# priority, generations — while the walk and the extraction pass run
# in a sidecar process through an IndexWorker::Backend (see
# index_worker.cr): the Crystal scheduler is single threaded and the
# UI must not share a heap with the indexer's allocations.
#
# The DEFAULT queue comes from the workspace root's own directory
# listing only (one readdir — cheap): one job per top-level folder
# (plus one for the root's loose files). fs-change events (the
# EventBus's "index.fs") append debounced per-file reindex jobs (a
# save storm owes one job per file) and lazy walk jobs for new
# directories. Among pending jobs, the one covering the active
# editor's file (the @prio_for proc) jumps the queue.
#
# A `generation` counter invalidates a worker mid-run when the
# project folder changes or a rescan is ordered: the backend is
# killed (closing its records channel — a blocked worker wakes with
# Channel::ClosedError) and a fresh worker generation takes over
# without touching the fresh state.
#
# Events emitted (synchronous on whichever fiber emits — see
# EventBus; handlers must not yield):
#   "index.updated"  a file's definitions swapped in (payload: path)
#   "queue.changed"  a job started, finished or was appended (payload: nil)

require "./event_bus"
require "./gitignore"
require "./index_worker"
require "./symbol_index"

module Kodkod
  class IndexQueue
    # One indexing unit: every file under one folder (a :scan job,
    # walked by the backend) or a single file (a :change job from a
    # debounced fs event).
    class Job
      getter folder : String          # absolute — the job's display unit
      property files : Array(String)  # filled for :change/root jobs
      getter reason : Symbol          # :scan | :change
      property id : Int32 = 0         # wire id, assigned on enqueue
      property state : Symbol = :pending # :pending | :running | :done
      property done : Int32 = 0
      property total : Int32          # files owed (the walk reports it)
      property? walked : Bool         # false until the backend walked it
      property retries : Int32 = 0    # backend crashes before :done

      def initialize(@folder : String, @files : Array(String),
                     @reason : Symbol = :scan, @walked : Bool = true)
        @total = @files.size
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

    # fs events sit in @dirty this long before becoming :change jobs —
    # a save storm or a checkout collapses into one job per file.
    DEBOUNCE = 300.milliseconds
    # A job the sidecar died on is retried at most this many times
    # before it is dropped as :done (empty) — a broken sidecar must
    # not wedge the queue.
    MAX_RETRIES = 3

    getter jobs : Array(Job) = [] of Job
    getter root : String? = nil
    getter generation : Int32 = 0
    getter? paused : Bool = false

    @backend_factory : ((String -> String?) -> IndexWorker::Backend)
    @backend : IndexWorker::Backend? = nil
    @running = 0
    @worker_gen = 0
    @next_id = 0
    @dirty = [] of String
    @debounce_armed = false

    def initialize(@index : SymbolIndex, @bus : EventBus,
                   @lang_for : String -> String? = ->(path : String) {
                     nil.as(String?)
                   },
                   @prio_for : -> String? = ->{ nil.as(String?) },
                   backend_factory : ((String -> String?) -> IndexWorker::Backend)? = nil)
      @backend_factory = backend_factory ||
                         ->(l : String -> String?) {
                           IndexWorker::Local.new(l).as(IndexWorker::Backend)
                         }
      @bus.on("index.fs") { |path| on_fs_event(path.to_s) }
      @bus.on("index.overflow") { rebuild }
    end

    # Point the queue at a new project root: drop everything, kill
    # the sidecar, build the lazy per-folder jobs from the root's own
    # listing, wake a worker. A paused queue resumes (a fresh root
    # makes no sense to keep on hold).
    def start(root : String) : Nil
      @generation += 1
      @root = root
      @jobs.clear
      @index.clear
      @dirty.clear
      @debounce_armed = false
      @paused = false
      @backend.try(&.kill)
      @backend = @backend_factory.call(@lang_for)
      self.class.initial_jobs(root).each { |j| add_job(j) }
      @bus.emit("queue.changed")
      force_spawn_worker
    end

    # Rescan the same root (the Reindex button, an fs-event overflow).
    def rebuild : Nil
      start(@root.not_nil!) if @root
    end

    # --- pause / resume / stop ------------------------------------------

    # Hold the queue: the sidecar is killed (an in-flight job returns
    # to :pending — the records already applied stay in the index),
    # pending jobs wait. Resume picks the queue back up.
    def pause : Nil
      return if @paused || @root.nil?
      @paused = true
      @backend.try(&.kill)
      @bus.emit("queue.changed")
    end

    # Resume after pause: a fresh backend (the old one's channel is
    # closed) and a worker.
    def resume : Nil
      return unless @paused
      @paused = false
      @backend.try(&.kill)
      @backend = @backend_factory.call(@lang_for)
      @bus.emit("queue.changed")
      spawn_worker
    end

    # Abort indexing outright: everything still owed (jobs, debounced
    # dirty paths) is dropped; what the index already holds stays.
    def stop : Nil
      @paused = false
      @dirty.clear
      @backend.try(&.kill)
      @jobs.each { |j| j.state = :done if j.active? }
      @bus.emit("queue.changed")
    end

    def busy? : Bool
      @running > 0
    end

    def pending : Array(Job)
      @jobs.select(&.active?)
    end

    def current : Job?
      @jobs.find { |j| j.state == :running }
    end

    # --- the default queue: the root's own listing --------------------

    # One lazy :scan job per non-ignored top-level folder (plus the
    # root's loose files, known immediately) — the backend does the
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
          add_job(Job.new(path, [] of String, walked: false))
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
        add_job(Job.new(p, [p], :change))
      end
      @bus.emit("queue.changed")
      spawn_worker
    end

    # --- the worker ----------------------------------------------------

    private def add_job(job : Job) : Job
      job.id = (@next_id += 1)
      @jobs << job
      job
    end

    # One worker fiber at a time (records are delivered to whichever
    # fiber receives — two would steal each other's lines). start()
    # supersedes through force_spawn_worker after killing the backend.
    # A paused queue holds its jobs until resume.
    private def spawn_worker : Nil
      return if @paused
      force_spawn_worker unless @running > 0
    end

    private def force_spawn_worker : Nil
      @running += 1
      gen = @generation
      wg = (@worker_gen += 1)
      spawn(name: "kodkod-index") do
        begin
          run(gen, wg)
        ensure
          @running -= 1
        end
      end
    end

    private def run(gen : Int32, wg : Int32) : Nil
      while @generation == gen && @worker_gen == wg && !@paused
        job = next_job || break
        backend = ensure_backend || break
        job.state = :running
        @bus.emit("queue.changed")
        dispatch(backend, job)
        # Drain the job's records until its :done (the backend is
        # sequential — one job's stream at a time).
        finished = false
        begin
          loop do
            rec = backend.records.receive
            break unless live?(gen, wg, job)
            next unless rec.job == job.id
            case rec.kind
            when :total
              job.total = rec.count
              @bus.emit("queue.changed")
            when :swap
              @index.replace(rec.path.not_nil!, rec.defs)
              job.done += 1
              @bus.emit("index.updated", rec.path)
            when :done
              finished = true
              break
            end
          end
        rescue Channel::ClosedError
          # the sidecar died or was killed mid-job
        end
        job.walked = true
        if job.state != :running
          # stop() already settled this job while we were blocked —
          # leave its fate alone
        elsif finished && live?(gen, wg, job)
          job.state = :done
        elsif @paused
          requeue_job(job)
        else
          # superseded or crashed: requeue (bounded) or drop
          job.retries += 1
          job.state = job.retries >= MAX_RETRIES ? :done : :pending
          requeue_job(job) if job.state == :pending
        end
        @bus.emit("queue.changed")
      end
      # A pause landing between records (not inside a blocked receive)
      # leaves the in-flight job :running — put it back. Only the
      # CURRENT worker may sweep: a superseded one must not touch the
      # new generation's running jobs. stop() marks jobs :done itself;
      # a superseding start() cleared them.
      if @worker_gen == wg
        @jobs.each { |j| requeue_job(j) if j.state == :running }
      end
    end

    # A killed backend (stop, a crashed sidecar) is replaced before it
    # is driven again — its records channel is closed forever, and a
    # retry against it would only bounce off Channel::ClosedError.
    private def ensure_backend : IndexWorker::Backend?
      if (b = @backend) && !b.records.closed?
        b
      elsif @root
        @backend = @backend_factory.call(@lang_for)
      end
    end

    # Back to the queue after an abort (pause, sidecar death): a lazy
    # scan must re-walk — the backend, not the parent, knows its
    # files, and dispatch of a walked-empty scan would send nothing.
    private def requeue_job(job : Job) : Nil
      job.state = :pending
      job.done = 0
      job.walked = false if job.scan?
    end

    private def live?(gen : Int32, wg : Int32, job : Job) : Bool
      @generation == gen && @worker_gen == wg && job.state == :running
    end

    # Hand the job to the backend (a lazy scan is walked there; a
    # walked scan or a change job carries its files' paths).
    private def dispatch(backend : IndexWorker::Backend, job : Job) : Nil
      if job.scan? && !job.walked?
        backend.folder(job.id, job.folder, @root.not_nil!)
      elsif (path = job.files.first?)
        backend.file(job.id, path)
      end
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
  end
end
