# kodkod — ReloadQueue: the disk-change prompt queue. FS events for
# open files land here (from the fswatch observation fiber); the app
# pumps it ONE modal at a time, and only when the user is back at the
# window (see KodkodApp#pump_reload_queue) — never a wall of modals.
# Entries are PATHS, not Docs: they must survive frames, dedup against
# each other (several external writes to one file owe ONE prompt), and
# outlive the Doc if its tab closes before the prompt shows.

module Kodkod
  class ReloadQueue
    @paths = [] of String

    def size : Int32
      @paths.size
    end

    def includes?(path : String) : Bool
      @paths.includes?(path)
    end

    # Enqueue unless already queued; returns whether it was added (the
    # caller repaints only on a real addition).
    def enqueue(path : String) : Bool
      return false if @paths.includes?(path)
      @paths << path
      true
    end

    # Pop the next path to prompt about — `prefer` (the active tab's
    # file) jumps the queue as the most relevant question.
    def dequeue(prefer : String? = nil) : String?
      if prefer && (i = @paths.index(prefer))
        @paths.delete_at(i)
        prefer
      else
        @paths.shift?
      end
    end

    def remove(path : String) : Nil
      @paths.delete(path)
    end

    def clear : Nil
      @paths.clear
    end
  end
end
