# kodkod — WatchFilter: the shared skip predicate for the workspace
# fswatch watches (the FileTree listing-cache watch and the indexer's
# folder watch). Arming a recursive inotify watch walks the WHOLE tree
# — one add_watch + stat per directory — so vendored noise must not be
# armed at all: hidden entries (`.git` above all) and subtrees the
# workspace root's .gitignore ignores are skipped outright.
#
# The trade: changes inside skipped subtrees raise no fs events, and
# the FileTree RECHECK mtime poll (0.5s) is the backstop that still
# refreshes them when expanded — while the indexer never looks at
# ignored files anyway. Only the ROOT .gitignore is consulted (nested
# ones are not) — over-watching a nested-ignored subtree is the only
# cost, and it is bounded.
require "./gitignore"

module Kodkod
  module WatchFilter
    # Single-entry memo: one workspace root is watched at a time. The
    # .gitignore is read once per root; edits during the session are
    # not reloaded (over-watching is the only possible staleness).
    @@cache_root : String? = nil
    @@cache_ignore : Gitignore? = nil

    # Whether the directory *path* (absolute, under *root*) must be
    # skipped when arming a recursive watch: hidden names and
    # root-.gitignore'd directories.
    def self.skip?(root : String, path : String) : Bool
      return true if File.basename(path).starts_with?('.')
      return false unless path.starts_with?(root)
      if @@cache_root != root
        @@cache_root = root
        @@cache_ignore = Gitignore.load(File.join(root, ".gitignore"))
      end
      if gi = @@cache_ignore
        prefix = root.ends_with?('/') ? root : root + '/'
        rel = path.lchop(prefix)
        gi.ignores?(rel, dir: true)
      else
        false
      end
    end

    # The skip proc for `FSWatch.watch(root, skip: …)` call sites.
    def self.skip_proc(root : String) : String -> Bool
      ->(path : String) { skip?(root, path) }
    end
  end
end
