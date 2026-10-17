# kodkod — SymbolExtractor: regex-level definition extraction for the
# project index — the "basic" tier of go-to-definition. Line-oriented
# patterns per language pull (name, kind, line, col) triples out of a
# source text; NO scoping or resolution, so a jump lands on every
# same-named definition, ranked by the app (same file, then same
# directory, then everything else).
#
# Patterns are deliberately anchored (`^\s*` + keyword) so commented
# definitions ("# def foo") never match; a name in a string can still
# fool them — that is the accepted basic-level trade-off.
#
# TOKEN-VALIDATED: when the language has a highlight.cr grammar, each
# regex hit is checked against the tokenizer — a match inside a PROSE
# token (comment, string, %-literal, heredoc, =begin block) is not a
# definition. This is what keeps `def end` inside a %w[...] word array
# out of the index — same classifier the editor's Ctrl-link layer
# uses (Syntax.linkable_scope?). Without a grammar (or over the size
# cap) the raw regex pass stands alone.

require "./syntax"

module Kodkod
  class SymbolExtractor
    # Matches EditorBuffer::HIGHLIGHT_MAX_CHARS — past half a
    # megabyte the synchronous tokenization stops being pocket
    # change; the raw pass still runs.
    TOKEN_MAX_CHARS = 512_000

    struct Hit
      getter name : String
      getter kind : Symbol
      getter line : Int32 # 0-based
      getter col : Int32  # char column of the name

      def initialize(@name, @kind, @line, @col)
      end
    end

    private record Pat, regex : Regex, kind : Symbol

    IDENT  = "[A-Za-z_][A-Za-z0-9_]*"
    RIDENT = "[A-Za-z_][A-Za-z0-9_]*[?!]?"

    # Crystal / Ruby method-ish definitions (def, macro) — the leading
    # visibility/abstract modifiers are Crystal's.
    DEF_LINE   = /^\s*(?:public\s+|private\s+|protected\s+|abstract\s+)*(?:def)\s+(#{RIDENT})/
    MACRO_LINE = /^\s*macro\s+(#{IDENT})/

    # C-family function definition heuristic: a return type, a name,
    # a parenthesized parameter list, then the opening brace on the
    # SAME line. Control keywords are filtered after the match.
    C_FUNC_LINE = /^\s*[A-Za-z_][A-Za-z0-9_:<>,\*\s\[\]&]*?\s([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*\{/
    C_NOT_FUNC  = {"if", "for", "while", "switch", "return", "sizeof", "foreach"}

    PATTERNS = {
      "crystal" => [
        Pat.new(DEF_LINE, :method),
        Pat.new(MACRO_LINE, :macro),
        # Nested first: "class App::Inner" must yield Inner, not App.
        Pat.new(/^\s*(?:class|module)\s+#{IDENT}(?:::|\s+)(#{IDENT})/, :class),
        Pat.new(/^\s*(?:abstract\s+)?(?:class|module|struct|enum|record)\s+(#{IDENT})/, :class),
      ] of Pat,
      "ruby" => [
        Pat.new(DEF_LINE, :method),
        Pat.new(/^\s*class\s+#{IDENT}(?:::|\s+)(#{IDENT})/, :class),
        Pat.new(/^\s*(?:class|module)\s+(#{IDENT})/, :class),
      ] of Pat,
      "python" => [
        Pat.new(/^\s*(?:async\s+)?def\s+(#{IDENT})/, :method),
        Pat.new(/^\s*class\s+(#{IDENT})/, :class),
      ] of Pat,
      "go" => [
        Pat.new(/^\s*func\s+(?:\([^)]*\)\s*)?(#{IDENT})/, :function),
        Pat.new(/^\s*type\s+(#{IDENT})\s+(?:struct|interface)\b/, :type),
      ] of Pat,
      "rust" => [
        Pat.new(/^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+(#{IDENT})/, :function),
        Pat.new(/^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait)\s+(#{IDENT})/, :type),
        Pat.new(/^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(#{IDENT})/, :module),
        Pat.new(/^\s*macro_rules!\s+(#{IDENT})/, :macro),
      ] of Pat,
      "c" => [
        Pat.new(/^\s*#\s*define\s+(#{IDENT})/, :macro),
        Pat.new(/^\s*(?:typedef\s+)?struct\s+(#{IDENT})/, :type),
        Pat.new(C_FUNC_LINE, :function),
      ] of Pat,
      "cpp" => [
        Pat.new(/^\s*#\s*define\s+(#{IDENT})/, :macro),
        Pat.new(/^\s*(?:typedef\s+)?(?:struct|class|enum)\s+(#{IDENT})/, :type),
        Pat.new(C_FUNC_LINE, :function),
      ] of Pat,
      "java" => [
        Pat.new(/^\s*(?:\w+\s+)*class\s+(#{IDENT})/, :class),
        Pat.new(C_FUNC_LINE, :method),
      ] of Pat,
      "csharp" => [
        Pat.new(/^\s*(?:\w+\s+)*class\s+(#{IDENT})/, :class),
        Pat.new(C_FUNC_LINE, :method),
      ] of Pat,
      "javascript" => [
        Pat.new(/(?:^|\s)(?:export\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)/, :function),
        Pat.new(/^\s*(?:export\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)/, :class),
        Pat.new(/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][A-Za-z0-9_$]*\s*=>)/, :function),
      ] of Pat,
      "typescript" => [
        Pat.new(/(?:^|\s)(?:export\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][A-Za-z0-9_$]*)/, :function),
        Pat.new(/^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)/, :class),
        Pat.new(/^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][A-Za-z0-9_$]*\s*=>)/, :function),
        Pat.new(/^\s*interface\s+([A-Za-z_$][A-Za-z0-9_$]*)/, :type),
      ] of Pat,
      "bash" => [
        Pat.new(/^\s*(?:function\s+)?(#{IDENT})\s*\(\)\s*\{/, :function),
      ] of Pat,
    } of String => Array(Pat)

    def self.indexable?(lang : String?) : Bool
      !lang.nil? && PATTERNS.has_key?(lang)
    end

    # All definition hits in `text` for `lang` (nil / unknown → none).
    def self.extract(text : String, lang : String?) : Array(Hit)
      return [] of Hit unless lang && (pats = PATTERNS[lang]?)
      spans = spans_for(text, lang)
      keywords = keywords_for(lang)
      hits = [] of Hit
      no = -1
      off = 0 # char offset of the current line's start
      text.each_line do |line|
        no += 1
        pats.each do |pat|
          if (m = pat.regex.match(line)) && (name = m[1]?)
            next if pat.kind == :function && C_NOT_FUNC.includes?(name)
            # A KEYWORD can never be a definition name — `def end`,
            # `def def` are grammar/literal artifacts (a %w[...] word
            # table, a doc sample), not methods. Checked BEFORE the
            # token validation on purpose: it holds even where
            # tokenization is unavailable (huge files, quirky heredocs).
            break if keywords.try(&.includes?(name))
            if spans && !Syntax.linkable_scope?(
                 scope_at(spans, off + (m.begin(1) || 0)))
              break # inside a comment/string literal — not a def
            end
            hits << Hit.new(name, pat.kind, no, m.begin(1).not_nil!)
            break # first pattern wins the line (def beats class etc.)
          end
        end
        off += line.size
      end
      hits
    end

    # --- the language's keyword set ----------------------------------
    #
    # highlight.cr grammars carry their keyword tables on the modes
    # (Mode#keywords: "a b c" | [..] | {"keyword": [..], ...}, plus
    # nested contains-modes with their own). The union, recursively —
    # the extractor's cheap, tokenization-independent guard.

    @@keyword_cache = {} of String => Set(String)?

    def self.keywords_for(lang : String) : Set(String)?
      if @@keyword_cache.has_key?(lang)
        return @@keyword_cache[lang]
      end
      set = Set(String).new
      if (mode = Syntax[lang])
        # Mode graphs are CYCLIC (grammars reuse mode objects in
        # several contains), so the walk tracks visited object ids.
        visited = Set(UInt64).new
        walk_mode(mode, set, visited)
      end
      @@keyword_cache[lang] = set.empty? ? nil : set
      @@keyword_cache[lang]
    end

    private def self.walk_mode(mode : Highlight::Mode, set : Set(String),
                               visited : Set(UInt64)) : Nil
      return unless visited.add?(mode.object_id)
      collect_keywords(mode.keywords, set)
      collect_keywords(mode.begin_keywords, set)
      if (contains = mode.contains)
        contains.each { |m| walk_mode(m, set, visited) }
      end
    end

    private def self.collect_keywords(val : Highlight::KeywordsVal?,
                                      set : Set(String)) : Nil
      case val
      when String        then val.split.each { |w| set << w }
      when Array(String) then val.each { |w| set << w }
      when Hash(String, Highlight::KeywordsVal)
        val.each_value { |v| collect_keywords(v, set) }
      end
    end

    # The tokenizer spans for validation (starts[i] = char offset of
    # token i), or nil when there is nothing to validate against
    # (no grammar for the lang, file over the cap).
    private def self.spans_for(text : String,
                               lang : String) : {Array(Int32), Array(Syntax::Token)}?
      return nil if text.size > TOKEN_MAX_CHARS
      toks = Syntax.highlight(text, lang) || return nil
      starts = Array(Int32).new(toks.size + 1, 0)
      acc = 0
      toks.each_with_index do |t, i|
        starts[i] = acc
        acc += t.text.size
      end
      starts[toks.size] = acc
      {starts, toks}
    end

    # The scope of the token containing char `offset` (nil when past
    # the end or between tokens — plain text, linkable).
    private def self.scope_at(spans : {Array(Int32), Array(Syntax::Token)},
                              offset : Int32) : String?
      starts, toks = spans
      lo = 0
      hi = toks.size # last token with starts[i] <= offset
      while lo < hi
        mid = (lo + hi) // 2
        if starts[mid] <= offset
          lo = mid + 1
        else
          hi = mid
        end
      end
      i = lo - 1
      return nil if i < 0 || i >= toks.size
      toks[i].scope
    end
  end
end
