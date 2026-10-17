# kodkod — EventBus: a tiny synchronous pub/sub used by the project
# indexer. Publishers (the fswatch observation fiber, the index worker
# fiber) and the app UI decouple through named string events with an
# optional string payload — no callback spaghetti across modules.
#
# Delivery is SYNCHRONOUS on the publishing fiber's stack: handlers
# must be quick and must not yield (the Crystal scheduler is
# cooperative; touching shared app state is safe mid-handler as long
# as nothing yields inside). Handlers are appended in subscribe order
# and all of them run for every emit — like every other observer
# list, keep them idempotent.

module Kodkod
  class EventBus
    alias Handler = String? ->

    def initialize
      @handlers = {} of String => Array(Handler)
    end

    # Subscribe `handler` to `event` (any name; no registry to declare).
    def on(event : String, &handler : Handler) : Nil
      (@handlers[event] ||= [] of Handler) << handler
    end

    # Fire `event`; every subscriber sees `data` (nil when nothing to
    # carry). A handler that emits another event re-enters #emit on
    # its own stack — order stays deterministic.
    def emit(event : String, data : String? = nil) : Nil
      @handlers[event]?.try &.each(&.call(data))
    end
  end
end
