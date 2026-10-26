require "spec"
require "file_utils"
require "../src/event_bus"
require "../src/gitignore"
require "../src/symbol_extractor"
require "../src/symbol_index"
require "../src/index_worker"

def worker_lang_for(path : String) : String?
  case File.extname(path)
  when ".cr" then "crystal"
  when ".py" then "python"
  else           nil
  end
end

describe Kodkod::IndexWorker do
  it "round-trips every record kind through the codec" do
    defs = [Kodkod::SymbolIndex::Def.new("helper", :method, "/tmp/a.cr", 1, 4)]
    recs = [
      Kodkod::IndexWorker::Record.total(7, 42),
      Kodkod::IndexWorker::Record.swap(7, "/tmp/a.cr", defs),
      Kodkod::IndexWorker::Record.done(7),
    ]
    recs.each do |rec|
      out = Kodkod::IndexWorker.decode(Kodkod::IndexWorker.encode(rec)).not_nil!
      out.job.should eq(rec.job)
      out.kind.should eq(rec.kind)
      out.count.should eq(rec.count)
      if rec.swap?
        out.path.should eq("/tmp/a.cr")
        out.defs.size.should eq(1)
        d = out.defs.first
        d.name.should eq("helper")
        d.kind.should eq(:method)
        d.line.should eq(1)
        d.col.should eq(4)
      end
    end
    # A garbled line decodes to nil, never raises.
    Kodkod::IndexWorker.decode("not json").should be_nil
    Kodkod::IndexWorker.decode(%({"j":1,"k":"bogus"})).should be_nil
  end

  it "serves folder and file commands over a loopback IO" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iw-#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, ".gitignore"), "vendor/\n")
      File.write(File.join(root, "src", "a.cr"), "module A\n  def helper\n  end\nend\n")
      File.write(File.join(root, "src", "skip.txt"), "def nope\nend\n")
      FileUtils.mkdir_p(File.join(root, "vendor"))
      File.write(File.join(root, "vendor", "v.cr"), "def v\nend\n")
      begin
        input = IO::Memory.new
        input << %({"cmd":"folder","j":1,"p":#{root.to_json},"r":#{root.to_json}}) << '\n'
        input << %({"cmd":"file","j":2,"p":#{File.join(root, "src", "a.cr").to_json}}) << '\n'
        input.rewind
        output = IO::Memory.new
        Kodkod::IndexWorker.run(input, output, ->worker_lang_for(String))
        recs = output.to_s.each_line
          .map { |l| Kodkod::IndexWorker.decode(l).not_nil! }.to_a

        # folder job: total (a.cr + skip.txt — no *.txt rule here),
        # a swap per walked file (skip.txt carries empty defs), done
        folder = recs.select(&.job.==(1))
        folder.size.should eq(4)
        folder.first.total?.should be_true
        folder.first.count.should eq(2)
        swaps = folder.select(&.swap?)
        swaps.map(&.path.not_nil!.lchop(root + "/")).sort
          .should eq(["src/a.cr", "src/skip.txt"])
        a_cr = swaps.find { |s| s.path.not_nil!.ends_with?("a.cr") }.not_nil!
        a_cr.defs.map(&.name).should contain("helper")
        folder.last.done?.should be_true

        # file job: swap + done
        one = recs.select(&.job.==(2))
        one.size.should eq(2)
        one.first.swap?.should be_true
        one.last.done?.should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "drives the in-process Local backend end to end" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-iw-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "a.cr"), "def helper\nend\n")
      begin
        index = Kodkod::SymbolIndex.new
        backend = Kodkod::IndexWorker::Local.new(->worker_lang_for(String))
        backend.folder(1, root, root)
        # Blocking receives (each yields the fiber) until the job's
        # :done lands; the channel closes only on kill.
        seen = [] of Kodkod::IndexWorker::Record
        spins = 0
        while seen.none?(&.done?) && spins < 20_000
          seen << (backend.records.receive rescue break)
          spins += 1
        end
        seen.any?(&.done?).should be_true
        swaps = seen.select(&.swap?)
        swaps.size.should eq(1)
        swaps.first.defs.map(&.name).should eq(["helper"])
        backend.kill
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
