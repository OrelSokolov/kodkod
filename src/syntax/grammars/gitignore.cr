# kodkod — Syntax grammar: .gitignore (highlight.js has none), written
# against the highlight.cr Mode API like the Crystal one. The line
# syntax per gitignore(5): a `#` comment (only from a line start), a
# leading `!` negation, glob metacharacters (`**`, `*`, `?`, character
# classes), and `\`-escaped metacharacters. The path text itself stays
# unscoped. `^`/`$` anchor per line — the engine compiles JS regexes
# with multiline semantics.

module Kodkod
  module Syntax
    module Grammars
      def self.gitignore(hljs : Highlight::HLJS) : Highlight::Mode
        Highlight::Mode.new.apply(
          name: "Gitignore",
          aliases: ["ignore"],
          contains: [
            # `#` opens a comment only at a line start; on a `\#` line
            # the escape below matches one char earlier, so it wins.
            hljs.comment(/^\#/, "$"),
            Highlight::Mode.new.apply(
              scope: "char.escape",
              match: /\\[#*?!\\\[\]]/
            ),
            Highlight::Mode.new.apply(
              # a leading `!` re-includes what an earlier line ignored
              scope: "keyword",
              match: /^!/
            ),
            Highlight::Mode.new.apply(
              scope: "regexp",
              match: /\*\*|\*|\?|\[[^\]\n]*\]/
            ),
          ] of Highlight::Mode
        )
      end
    end
  end
end

fn = ->(hljs : Highlight::HLJS) { Kodkod::Syntax::Grammars.gitignore(hljs) }
Highlight::Languages.register("gitignore", fn)
Highlight::HLJS.default.register_language("gitignore", fn)
