require "spec"
require "../src/event_bus"

describe Kodkod::EventBus do
  it "delivers to subscribers with the payload" do
    bus = Kodkod::EventBus.new
    got = [] of String?
    bus.on("index.updated") { |p| got << p }
    bus.emit("index.updated", "src/app.cr")
    got.should eq(["src/app.cr"])
  end

  it "runs handlers in subscribe order" do
    bus = Kodkod::EventBus.new
    order = [] of Int32
    bus.on("e") { |_p| order << 1 }
    bus.on("e") { |_p| order << 2 }
    bus.emit("e")
    order.should eq([1, 2])
  end

  it "ignores events nobody subscribed to" do
    bus = Kodkod::EventBus.new
    bus.emit("nothing")
  end

  it "supports a nil payload" do
    bus = Kodkod::EventBus.new
    got = [] of String?
    bus.on("e") { |p| got << p }
    bus.emit("e")
    got.should eq([nil])
  end
end
