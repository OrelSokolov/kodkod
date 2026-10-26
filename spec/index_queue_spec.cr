require "spec"
require "file_utils"
require "../src/event_bus"
require "../src/gitignore"
require "../src/symbol_extractor"
require "../src/symbol_index"
require "../src/index_queue"

# Drain the queue's worker fiber (cooperative: yields until idle).
def drain_queue(q : Kodkod::IndexQueue, max_spins : Int32 = 20_000) : Nil
  spins = 0
  while q.busy? && spins < max_spins
    Fiber.yield
    spins += 1
  end
end

def lang_for(path : String) : String?
  case File.extname(path)
  when ".cr" then "crystal"
  when ".py" then "python"
  else           nil
  end
end

describe Kodkod::IndexQueue do
  it "builds per-folder jobs from a gitignore-aware walk" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(root, "src", "deep"))
      FileUtils.mkdir_p(File.join(root, "vendor"))
      FileUtils.mkdir_p(File.join(root, "skipped"))
      File.write(File.join(root, ".gitignore"), "vendor/\nskipped/\n*.txt\n")
      File.write(File.join(root, "main.cr"), "def main\nend\n")
      File.write(File.join(root, "notes.txt"), "def not_indexed\nend\n")
      File.write(File.join(root, "src", "app.cr"), "def app\nend\n")
      File.write(File.join(root, "src", "deep", "low.py"), "def low():\n    pass\n")
      File.write(File.join(root, "vendor", "v.cr"), "def v\nend\n")
      File.write(File.join(root, "skipped", "s.cr"), "def s\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)
        # One job for the root's loose files + one per live top dir,
        # walked by the backend (job.files stays empty for lazy scans
        # — the parent only learns the count).
        folders = q.jobs.map { |j| j.folder == root ? "." : File.basename(j.folder) }.sort
        folders.should eq([".", "src"])
        q.jobs.first.folder.should eq(root)
        q.jobs.first.files.map { |p| p.lchop(root + "/") }.should eq(["main.cr"])
        q.jobs[1].total.should eq(2) # src/app.cr + src/deep/low.py
        index.has_name?("main").should be_true
        index.has_name?("app").should be_true
        index.has_name?("low").should be_true
        index.has_name?("not_indexed").should be_false
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "indexes the project and emits events" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "src", "a.cr"), "module A\n  def helper\n  end\nend\n")
      File.write(File.join(root, "b.py"), "def b():\n    pass\n")
      File.write(File.join(root, "c.txt"), "no definitions here\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        updated = [] of String?
        bus.on("index.updated") { |p| updated << p }
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)
        q.busy?.should be_false
        q.jobs.all?(&.state.== :done).should be_true
        index.has_name?("helper").should be_true
        index.has_name?("b").should be_true
        index.lookup("helper").first.path.should eq(
          File.join(root, "src", "a.cr"))
        index.lookup("helper").first.line.should eq(1)
        updated.size.should be >= 2
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "reindexes a changed file through the fs event" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      path = File.join(root, "a.cr")
      File.write(path, "def before\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)
        index.has_name?("before").should be_true

        File.write(path, "def after\nend\n")
        bus.emit("index.fs", path)
        q.flush # the debounce timer's callback, pumped by hand
        drain_queue(q)
        index.has_name?("before").should be_false
        index.has_name?("after").should be_true
        # A :change job joined the queue and finished.
        q.jobs.count { |j| !j.scan? && j.state == :done }.should eq(1)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "coalesces a save storm into one change job" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      path = File.join(root, "a.cr")
      File.write(path, "def v1\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)

        3.times do |i|
          File.write(path, "def v#{i + 1}\nend\n")
          bus.emit("index.fs", path)
        end
        q.flush
        drain_queue(q)
        index.has_name?("v3").should be_true
        q.jobs.count { |j| !j.scan? && j.state == :done }.should eq(1)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "aborts an in-flight job on pause and finishes it after resume" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "src", "a.cr"), "def held\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        q.pause # possibly mid-job — wherever the worker is
        drain_queue(q)
        q.paused?.should be_true
        q.jobs.any? { |j| j.state == :running }.should be_false
        q.resume
        drain_queue(q)
        index.has_name?("held").should be_true
        q.jobs.all?(&.state.== :done).should be_true
        q.paused?.should be_false
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "holds fs-event jobs while paused and runs them on resume" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      path = File.join(root, "a.cr")
      File.write(path, "def before\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)

        q.pause
        File.write(path, "def after\nend\n")
        bus.emit("index.fs", path)
        q.flush # enqueue despite the pause
        drain_queue(q)
        index.has_name?("after").should be_false
        q.jobs.any?(&.active?).should be_true

        q.resume
        drain_queue(q)
        index.has_name?("after").should be_true
        q.jobs.all?(&.state.== :done).should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "drops owed work on stop but keeps the queue usable" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      path = File.join(root, "a.cr")
      File.write(path, "def first\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)

        File.write(path, "def dropped\nend\n")
        bus.emit("index.fs", path)
        q.pause
        q.flush # the change job sits pending
        q.stop
        q.paused?.should be_false
        q.jobs.all?(&.state.== :done).should be_true
        drain_queue(q)
        index.has_name?("dropped").should be_false

        # stop does not brick the queue: later events index normally
        File.write(path, "def revived\nend\n")
        bus.emit("index.fs", path)
        q.flush
        drain_queue(q)
        index.has_name?("revived").should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "indexes the active file's folder first" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(root, "aaa"))
      FileUtils.mkdir_p(File.join(root, "zzz"))
      File.write(File.join(root, "aaa", "a.cr"), "def a\nend\n")
      File.write(File.join(root, "zzz", "z.cr"), "def z\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        updated = [] of String?
        bus.on("index.updated") { |p| updated << p }
        active = File.join(root, "zzz", "z.cr")
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String),
          ->{ active.as(String?) })
        q.start(root)
        drain_queue(q)
        # The zzz job covered the active file, so z.cr indexed first.
        updated.first.should eq(active)
        q.jobs.all?(&.state.== :done).should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "drops deleted files from the index" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      path = File.join(root, "a.cr")
      File.write(path, "def gone\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)
        index.has_name?("gone").should be_true

        File.delete(path)
        bus.emit("index.fs", path)
        index.has_name?("gone").should be_false
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rescans wholesale on rebuild with a fresh generation" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iq-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "a.cr"), "def first\nend\n")
      begin
        bus = Kodkod::EventBus.new
        index = Kodkod::SymbolIndex.new
        q = Kodkod::IndexQueue.new(index, bus, ->lang_for(String))
        q.start(root)
        drain_queue(q)

        File.write(File.join(root, "a.cr"), "def second\nend\n")
        q.rebuild
        drain_queue(q)
        index.has_name?("first").should be_false
        index.has_name?("second").should be_true
        q.jobs.size.should eq(1) # the rebuild dropped the old jobs
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
