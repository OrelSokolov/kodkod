# kodkod — SymbolIndex: the in-memory go-to-definition database. The
# indexer worker REPLACES a file's definitions wholesale (the disk is
# the source of truth — one write, one swap, no merge), so the two
# maps stay coherent through a single code path:
#
#   name → definitions   the jump lookup (exact match; the app also
#                        tries the Crystal/Ruby `?`/`!` variants)
#   path → definitions   per-file invalidation on reindex/delete
#
# No persistence on purpose: a plain rebuild of a mid-size project
# takes well under a second of background time, and a warm cache file
# would only add staleness questions. `version` bumps on every swap
# so the editor/UI can notice freshness without diffs.

module Kodkod
  class SymbolIndex
    struct Def
      getter name : String
      getter kind : Symbol # :method :class :module :macro :type :function :constant
      getter path : String # absolute
      getter line : Int32   # 0-based (the editor's caret coordinates)
      getter col : Int32    # char column of the name's first char

      def initialize(@name, @kind, @path, @line, @col)
      end

      def to_s(io : IO) : Nil
        io << name << " (" << kind << ") " << path << ":" << (line + 1)
      end
    end

    @by_name = {} of String => Array(Def)
    @by_path = {} of String => Array(Def)
    @version = 0_u64

    def version : UInt64
      @version
    end

    def clear : Nil
      return if @by_path.empty? && @by_name.empty?
      @by_name.clear
      @by_path.clear
      @version += 1
    end

    # Swap in `defs` as the current definition set of `path` (an empty
    # list drops the file from the index). Returns how many
    # definitions the file now carries.
    def replace(path : String, defs : Array(Def)) : Int32
      remove(path)
      unless defs.empty?
        @by_path[path] = defs
        defs.each { |d| (@by_name[d.name] ||= [] of Def) << d }
      end
      @version += 1
      defs.size
    end

    def remove(path : String) : Nil
      return unless (old = @by_path.delete(path))
      old.each do |d|
        next unless (list = @by_name[d.name]?)
        list.delete(d)
        @by_name.delete(d.name) if list.empty?
      end
      @version += 1
    end

    # Drop every indexed file under a deleted directory.
    def remove_prefix(prefix : String) : Nil
      @by_path.keys.each do |path|
        remove(path) if path.starts_with?(prefix)
      end
    end

    def lookup(name : String) : Array(Def)
      @by_name[name]? || [] of Def
    end

    # Fast membership for the editor's Ctrl-link highlighting (one
    # hash probe per identifier run per frame).
    def has_name?(name : String) : Bool
      @by_name.has_key?(name)
    end

    def files_indexed : Int32
      @by_path.size
    end

    def def_count : Int32
      # Names can repeat across files; the count is of DEFS, not keys.
      @by_path.values.sum(&.size)
    end

    # Every definition, ordered file-then-position — the debugging
    # table on the Indexing page reads this.
    def defs : Array(Def)
      out = [] of Def
      @by_path.keys.sort!.each do |path|
        out.concat(@by_path[path].sort_by! { |d| {d.line, d.col} })
      end
      out
    end
  end
end
