require "spec"
require "../src/reload_queue"

describe Kodkod::ReloadQueue do
  it "enqueues once per path (several writes owe one prompt)" do
    q = Kodkod::ReloadQueue.new
    q.enqueue("/tmp/a.cr").should be_true
    q.enqueue("/tmp/a.cr").should be_false
    q.size.should eq(1)
    q.includes?("/tmp/a.cr").should be_true
  end

  it "dequeues FIFO and empties out" do
    q = Kodkod::ReloadQueue.new
    q.enqueue("/tmp/a.cr")
    q.enqueue("/tmp/b.cr")
    q.dequeue.not_nil!.should eq("/tmp/a.cr")
    q.dequeue.not_nil!.should eq("/tmp/b.cr")
    q.dequeue.should be_nil
  end

  it "lets the preferred path jump the queue" do
    q = Kodkod::ReloadQueue.new
    q.enqueue("/tmp/a.cr")
    q.enqueue("/tmp/b.cr")
    q.enqueue("/tmp/c.cr")
    q.dequeue("/tmp/c.cr").should eq("/tmp/c.cr")
    q.dequeue.not_nil!.should eq("/tmp/a.cr")
    # A prefer that is not queued changes nothing.
    q.dequeue("/tmp/zz.cr").should eq("/tmp/b.cr")
    q.dequeue("/tmp/zz.cr").should be_nil
  end

  it "removes a closed tab's path and clears" do
    q = Kodkod::ReloadQueue.new
    q.enqueue("/tmp/a.cr")
    q.enqueue("/tmp/b.cr")
    q.remove("/tmp/a.cr")
    q.size.should eq(1)
    q.clear
    q.size.should eq(0)
  end
end
