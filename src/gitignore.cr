# kodkod — Gitignore: a basic .gitignore(5) parser and matcher, the
# gatekeeper of the project-indexer walk (the default indexing queue
# skips ignored subtrees, like git itself would).
#
# Supported: comments (#) and blank lines, trailing-space stripping,
# `!` negation, trailing `/` (directory-only), leading `/` or an
# embedded `/` anchoring the pattern to the .gitignore's directory,
# `*` / `?` (never across `/`), `[...]` / `[!...]` character classes,
# and the `**` forms — leading `**/`, trailing `/**`, and `/**/`.
# Not supported: `\`-escaped metacharacters beyond the leading `\#`
# and `\!`, per-dir precedence subtleties (the CALLER walks with a
# stack of Gitignores and lets the deepest matching one decide).
#
# Matching semantics: rules apply in FILE order, the LAST matching
# rule wins (a later `!pattern` un-ignores what an earlier line
# ignored). Paths are `/`-separated and relative to the directory
# holding the .gitignore; `dir: true` says the subject is a
# directory (dir-only rules apply, plain rules match it too — the
# caller prunes the subtree when a directory matches).

module Kodkod
  class Gitignore
    private struct Rule
      getter regex : Regex
      getter? negated : Bool
      getter? dir_only : Bool

      def initialize(@regex : Regex, @negated : Bool, @dir_only : Bool)
      end
    end

    def self.load(path : String) : self?
      return nil unless File.file?(path)
      begin
        new(File.read(path))
      rescue IO::Error | File::Error
        nil
      end
    end

    def initialize(content : String)
      @rules = [] of Rule
      content.each_line do |raw|
        line = raw.rstrip(' ')
        next if line.empty? || line.starts_with?('#')
        # An escaped leading # or ! is a literal part of the pattern.
        literal_lead = false
        if line.starts_with?("\\#") || line.starts_with?("\\!")
          line = line.lchop('\\')
          literal_lead = true
        end
        parse(line, literal_lead)
      end
    end

    private def parse(line : String, literal_lead : Bool = false) : Nil
      negated = !literal_lead && line.starts_with?('!')
      line = line.lchop('!') if negated
      dir_only = line.ends_with?('/')
      line = line.rstrip('/')
      return if line.empty?
      # A pattern with a slash ANYWHERE (other than the trailing one
      # just stripped) is anchored to this directory.
      anchored = line.includes?('/')
      line = line.lchop('/') if line.starts_with?('/')
      @rules << Rule.new(Regex.new(compile(line, anchored)), negated,
        dir_only)
    end

    # Glob → anchored regex source matching a WHOLE relative path.
    private def compile(pat : String, anchored : Bool) : String
      src = String.build do |io|
        io << '^'
        io << "(?:.*/)?" unless anchored # any depth, then the pattern
        chars = pat.chars
        i = 0
        n = chars.size
        while i < n
          c = chars[i]
          case c
          when '*'
            if chars[i + 1]? == '*' # ** forms
              if i.zero? && chars[i + 2]? == '/'
                io << "(?:.*/)?" # leading **/
                i += 3
                next
              elsif i + 2 == n && i > 0 && chars[i - 1]? == '/'
                io << ".*" # trailing /** — everything inside
                i += 2
                next
              elsif chars[i - 1]? == '/' && chars[i + 2]? == '/'
                io << "(?:.*/)?" # middle /**/ — zero or more dirs
                i += 3
                next
              end
              io << "[^/]*" # a stray ** behaves like *
              i += 2
              next
            end
            io << "[^/]*"
          when '?'
            io << "[^/]"
          when '['
            # Character class: copy to the closing ']', a leading ! or ^
            # inside negates. An unterminated '[' is a literal.
            j = i + 1
            j += 1 if chars[j]? == '!' || chars[j]? == '^'
            while j < n && chars[j]? != ']'
              j += 1
            end
            if chars[j]? == ']'
              io << '['
              io << '^' if chars[i + 1]? == '!'
              (i + 1...j).each { |k| io << chars[k] unless chars[k] == '!' && k == i + 1 }
              io << ']'
              i = j + 1
              next
            end
            io << Regex.escape(c.to_s)
          else
            io << Regex.escape(c.to_s)
          end
          i += 1
        end
        io << "\\z"
      end
      src
    end

    def empty? : Bool
      @rules.empty?
    end

    # Whether `rel` (relative to the .gitignore's directory, `/`
    # separators) is ignored. `dir: true` when the subject is a
    # directory — dir-only rules then apply, and the caller is
    # expected to skip the whole subtree (git's real behavior).
    def ignores?(rel : String, dir : Bool = false) : Bool
      ignored = false
      @rules.each do |rule|
        next if rule.dir_only? && !dir
        if rule.regex.matches?(rel)
          ignored = !rule.negated?
        end
      end
      ignored
    end
  end
end
