# kodkod — Syntax grammar: Crystal (highlight.js has none), written
# against the highlight.cr Mode API and registered into the shard's
# default HLJS instance. Heredocs/interpolation are approximated (no
# on:begin callbacks, as in the previous built-in grammar): a heredoc
# is a begin/end mode that stays open until its terminator line.

module Kodkod
  module Syntax
    module Grammars
      def self.crystal(hljs : Highlight::HLJS) : Highlight::Mode
        keywords = {} of String => Highlight::KeywordsVal
        keywords["keyword"] = %w[
          def end if elsif else unless while until for do then
          begin case when break next redo retry return yield
          require class module struct enum include extend rescue
          ensure alias undef and or not is_a responds_to as
          typeof union pointerof instance_sizeof sizeof
          private protected select spawn of
        ]
        keywords["literal"] = %w[true false nil]
        keywords["built_in"] = %w[self super __FILE__ __DIR__ ARGV ENV]

        escape = Highlight::Mode.new.apply(
          scope: "char.escape",
          match: /\\./
        )

        dquote = Highlight::Mode.new.apply(
          scope: "string",
          begin: /"/,
          end: /"/,
          contains: [escape] of Highlight::Mode
        )

        squote = Highlight::Mode.new.apply(
          scope: "string",
          begin: /'/,
          end: /'/,
          contains: [escape] of Highlight::Mode
        )

        heredoc = Highlight::Mode.new.apply(
          scope: "string",
          begin: /<<[-~]?[A-Z_]+\w*/,
          end: Regex.new("^[ \\t]*[A-Z_]+\\w*$", :multiline)
        )

        Highlight::Mode.new.apply(
          name: "Crystal",
          aliases: ["cr"],
          keywords: keywords,
          contains: [
            hljs.comment("#", "$"),
            dquote,
            squote,
            heredoc,
            Highlight::Mode.new.apply(
              scope: "symbol",
              match: /:[a-zA-Z_]\w*[?!]?/
            ),
            Highlight::Mode.new.apply(
              scope: "variable",
              match: /@[a-zA-Z_]\w*[?!]?/
            ),
            Highlight::Mode.new.apply(
              scope: "number",
              match: /\d[\d_]*((\.[\d_]+)?([eE][+-]?\d+)?)?|0[xob][0-9a-fA-F_]+/
            ),
            Highlight::Mode.new.apply(
              scope: "regexp",
              match: Regex.new("/(?!/)(\\\\.|\\[[^\\]]*\\]|[^/\\\\\\n])+/[a-z]*")
            ),
          ] of Highlight::Mode
        )
      end
    end
  end
end

fn = ->(hljs : Highlight::HLJS) { Kodkod::Syntax::Grammars.crystal(hljs) }
Highlight::Languages.register("crystal", fn)
Highlight::HLJS.default.register_language("crystal", fn)
