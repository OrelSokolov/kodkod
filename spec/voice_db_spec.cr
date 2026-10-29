require "spec"
require "file_utils"
require "../src/voice/db"

describe Kodkod::Voice::DB do
  it "inserts, claims, and resolves queue rows" do
    dir = File.join(Dir.tempdir, "kodkod-vdb-#{Random.new.hex(6)}")
    db = Kodkod::Voice::DB.open(dir)
    a = db.insert("/proj", "a.wav", 1000)
    b = db.insert("/proj", "b.wav", 2000)
    db.insert("/other", "c.wav", 3000)

    # FIFO claim
    rec = db.claim_next.not_nil!
    rec.id.should eq a
    rec.status.should eq "running"
    db.set_result(a, "done", "привет мир", nil, "gigaam")
    done = db.get(a).not_nil!
    done.status.should eq "done"
    done.transcript.should eq "привет мир"
    done.engine.should eq "gigaam"

    rec2 = db.claim_next.not_nil!
    rec2.id.should eq b
    db.set_result(b, "failed", nil, "движок недоступен", "gigaam")
  ensure
    db.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "filters the list by project, newest first" do
    dir = File.join(Dir.tempdir, "kodkod-vdb-#{Random.new.hex(6)}")
    db = Kodkod::Voice::DB.open(dir)
    a = db.insert("/proj", "a.wav", 1000)
    b = db.insert("/proj", "b.wav", 2000)
    db.insert("/other", "c.wav", 3000)
    db.list("/proj").map(&.id).should eq [b, a]
    db.list(nil).size.should eq 3
    db.list("/missing").should be_empty
  ensure
    db.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "requeues done and failed rows, but never a running one" do
    dir = File.join(Dir.tempdir, "kodkod-vdb-#{Random.new.hex(6)}")
    db = Kodkod::Voice::DB.open(dir)
    a = db.insert("/p", "a.wav", 1)
    db.set_result(a, "failed", nil, "x", "g")
    db.requeue(a).should be_true
    db.get(a).not_nil!.status.should eq "queued"

    running = db.claim_next.not_nil!
    running.id.should eq a
    db.requeue(a).should be_false # claimed by the worker
    db.get(a).not_nil!.status.should eq "running"
  ensure
    db.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "recovers running rows as queued on reopen (crash recovery)" do
    dir = File.join(Dir.tempdir, "kodkod-vdb-#{Random.new.hex(6)}")
    db = Kodkod::Voice::DB.open(dir)
    a = db.insert("/p", "a.wav", 1)
    db.claim_next.not_nil!.id.should eq a
    db.close
    # Simulate a crash: reopen without set_result.
    db2 = Kodkod::Voice::DB.open(dir)
    db2.get(a).not_nil!.status.should eq "queued"
  ensure
    db.try(&.close)
    db2.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "counts queued and running rows" do
    dir = File.join(Dir.tempdir, "kodkod-vdb-#{Random.new.hex(6)}")
    db = Kodkod::Voice::DB.open(dir)
    db.queued_count.should eq 0
    a = db.insert("/p", "a.wav", 1)
    db.insert("/p", "b.wav", 1)
    db.queued_count.should eq 2
    db.claim_next.not_nil!.id.should eq a
    db.queued_count.should eq 2 # queued + running both outstanding
    db.set_result(a, "done", "t", nil, "g")
    db.queued_count.should eq 1
  ensure
    db.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "deletes rows" do
    dir = File.join(Dir.tempdir, "kodkod-vdb-#{Random.new.hex(6)}")
    db = Kodkod::Voice::DB.open(dir)
    a = db.insert("/p", "a.wav", 1)
    db.delete(a)
    db.get(a).should be_nil
    db.list(nil).should be_empty
  ensure
    db.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end
end
