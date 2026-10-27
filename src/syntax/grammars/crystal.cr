# kodkod — Syntax grammar: Crystal (highlight.js has none), written
# against the highlight.cr Mode API and registered into the shard's
# default HLJS instance. Heredocs/interpolation are approximated (no
# on:begin callbacks, as in the previous built-in grammar): a heredoc
# is a begin/end mode that stays open until its terminator line.
#
# Scope names mirror the shard's Ruby grammar (title.class,
# title.function, variable.language, variable.constant, subst, params)
# so that Ruby and Crystal — the same language family — paint
# identically through the shared palette.

module Kodkod
  module Syntax
    module Grammars
      def self.crystal(hljs : Highlight::HLJS) : Highlight::Mode
        regex = Highlight::RegexHelpers

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
        # Same scopes the Ruby grammar gives these words (self/super →
        # variable.language, __FILE__-likes → variable.constant).
        keywords["variable.language"] = %w[self super]
        keywords["variable.constant"] = %w[__FILE__ __DIR__]
        keywords["built_in"] = %w[ARGV ENV]

        escape = Highlight::Mode.new.apply(
          scope: "char.escape",
          match: /\\./
        )

        subst = Highlight::Mode.new.apply(
          scope: "subst",
          begin: /#\{/,
          end: /\}/,
          keywords: keywords
        )

        dquote = Highlight::Mode.new.apply(
          scope: "string",
          begin: /"/,
          end: /"/,
          contains: [escape, subst] of Highlight::Mode
        )

        squote = Highlight::Mode.new.apply(
          scope: "string",
          begin: /'/,
          end: /'/,
          contains: [escape, subst] of Highlight::Mode
        )

        heredoc = Highlight::Mode.new.apply(
          scope: "string",
          begin: /<<[-~]?[A-Z_]+\w*/,
          end: Regex.new("^[ \\t]*[A-Z_]+\\w*$", :multiline),
          contains: [escape, subst] of Highlight::Mode
        )

        # %-literals: %w[...] %i(...) %q{...} %Q<...> %( ... ) and the
        # same-char delimiter forms, ruby-grammar style (crystal has
        # the same literals; %r is a regexp literal). Without these
        # the words inside a %w[def end if] array keyword-ized as
        # CODE — the project indexer then honestly found a "def end"
        # definition inside a literal (see SymbolExtractor's token
        # validation).
        percent_lits = ['(', '[', '{', '<', '/', '|', '%', '-'].flat_map do |open|
          close = {'(' => ')', '[' => ']', '{' => '}', '<' => '>'}[open]? || open
          [{"%[qQiIwWx]?\\#{open}", close, "string"},
           {"%r\\#{open}", close, "regexp"}].map do |begin_p, close_p, scope|
            Highlight::Mode.new.apply(
              scope: scope,
              begin: Regex.new(begin_p),
              end: Regex.new("\\#{close_p}")
            )
          end
        end

        # --- Ruby-grammar scope shapes (ruby.cr in the shard) ---

        method_re = "([a-zA-Z_]\\w*[!?=]?|[-+~]@|<<|>>|=~|===?|<=>|[<>]=?|\\*\\*|[-/+%^&*~`|]|\\[\\]=?)"
        class_name_re = regex.either([
          /\b([A-Z]+[a-z0-9]+)+/,
          /\b([A-Z]+[a-z0-9]+)+[A-Z]+/,
        ])
        class_name_ns_re = regex.concat(class_name_re, /(::\w+)*/)

        params = Highlight::Mode.new.apply(
          variants: [
            Highlight::Mode.new.apply(match: /\(\)/),
            Highlight::Mode.new.apply(
              scope: "params",
              begin: /\(/,
              end: /(?=\))/,
              exclude_begin: true,
              ends_parent: true,
              keywords: keywords
            ),
          ] of Highlight::Mode
        )

        method_definition = Highlight::Mode.new.apply(
          match: [/def/, /\s+/, method_re],
          scope: {"1" => "keyword", "3" => "title.function"},
          contains: [params] of Highlight::Mode
        )

        class_definition = Highlight::Mode.new.apply(
          variants: [
            Highlight::Mode.new.apply(
              match: [/class\s+/, class_name_ns_re, /\s+<\s+/, class_name_ns_re]
            ),
            Highlight::Mode.new.apply(
              match: [/\b(class|module|struct|enum|lib)\s+/, class_name_ns_re]
            ),
          ] of Highlight::Mode,
          scope: {"2" => "title.class", "4" => "title.class.inherited"},
          keywords: keywords
        )

        include_extend = Highlight::Mode.new.apply(
          match: [/(include|extend)\s+/, class_name_ns_re],
          scope: {"2" => "title.class"},
          keywords: keywords
        )

        object_creation = Highlight::Mode.new.apply(
          relevance: 0,
          match: [class_name_ns_re, /\.new[. (]/],
          scope: {"1" => "title.class"}
        )

        upper_case_constant = Highlight::Mode.new.apply(
          relevance: 0,
          match: /\b[A-Z][A-Z_0-9]+\b/,
          scope: "variable.constant"
        )

        class_reference = Highlight::Mode.new.apply(
          relevance: 0,
          match: class_name_re,
          scope: "title.class"
        )

        # Type annotations (`ctx : Egui::Context`, `) : Nil`,
        # `@stats_text : String?`) are painted as comments: the bright
        # class/title/params colors make def signatures shout. The
        # scope is `comment.annotation` — the palette's longest-prefix
        # fallback keeps the comment color, while the distinct name
        # lets the editor address annotations (e.g. to hide them)
        # without touching real comments. Atoms:
        # `Foo`, `Foo::Bar`, `Array(String)?`; unions with `|`.
        base_type = "[A-Z]\\w*(?:::\\w+)*"
        type_atom = "#{base_type}(?:[ \\t]*\\([^)]*\\))?\\??"
        type_expr = "#{type_atom}(?:[ \\t]*\\|[ \\t]*#{type_atom})*"
        annotation_re = Regex.new("[ \\t]*:[ \\t]*" + type_expr)

        param_type_annotation = Highlight::Mode.new.apply(
          relevance: 0,
          match: annotation_re,
          scope: "comment.annotation"
        )

        # `) : Nil` — the `)` keeps its own color, the annotation dims.
        # Root-level only: inside params its begin at `)` would beat the
        # zero-width params end `(?=\))` at the same position and the
        # params mode would never close.
        return_type_annotation = Highlight::Mode.new.apply(
          relevance: 0,
          match: [/\)/, annotation_re] of (String | Regex),
          scope: {"2" => "comment.annotation"}
        )

        # `@x : String? = nil` — the ivar stays `variable`, the
        # annotation dims (also covers `def initialize(@x : Int32)`).
        # `@@?` — both ivars and class vars (`@@count`), as in the
        # shard's Ruby grammar.
        ivar_type_annotation = Highlight::Mode.new.apply(
          relevance: 0,
          match: [/@@?[a-zA-Z_]\w*[?!]?/, annotation_re] of (String | Regex),
          scope: {"1" => "variable", "2" => "comment.annotation"}
        )

        # `[] of Foo` / `{} of K => V` — the `of <type>` tail dims the
        # same way as annotations (uniform color; also keeps `::` in
        # the type from splitting into a bright `Egui` class plus a
        # `:Event` symbol).
        of_type_annotation = Highlight::Mode.new.apply(
          relevance: 0,
          match: Regex.new("[ \\t]*of[ \\t]*" + type_expr + "(?:[ \\t]*=>[ \\t]*" + type_expr + ")?"),
          scope: "comment.annotation"
        )

        block_params = Highlight::Mode.new.apply(
          scope: "params",
          begin: /\|(?!=)/,
          end: /\|/,
          exclude_begin: true,
          exclude_end: true,
          relevance: 0,
          keywords: keywords
        )

        base_contains = [hljs.comment("#", "$"), dquote, squote, heredoc] of Highlight::Mode +
                        percent_lits +
                        [ivar_type_annotation, of_type_annotation,
                         class_definition, include_extend, object_creation,
                         upper_case_constant, class_reference, method_definition] of Highlight::Mode +
                        [block_params] of Highlight::Mode +
                           [
                             Highlight::Mode.new.apply(
                               scope: "symbol",
                               match: /:[a-zA-Z_]\w*[?!]?/
                             ),
                             Highlight::Mode.new.apply(
                               scope: "variable",
                               match: /@@?[a-zA-Z_]\w*[?!]?/
                             ),
                             # \b keeps digits inside identifiers (app2,
                             # ctx2) from matching; hex/oct/bin first so
                             # 0xff is not split into 0 + xff.
                             Highlight::Mode.new.apply(
                               scope: "number",
                               match: /\b0[xob][0-9a-fA-F_]+|\b\d[\d_]*((\.[\d_]+)?([eE][+-]?\d+)?)?/
                             ),
                             Highlight::Mode.new.apply(
                               scope: "regexp",
                               match: Regex.new("/(?!/)(\\\\.|\\[[^\\]]*\\]|[^/\\\\\\n])+/[a-z]*")
                             ),
                           ] of Highlight::Mode

        default_contains = [return_type_annotation] of Highlight::Mode + base_contains

        # Ruby-style: code inside #{...} and |params| is full code. Inside
        # def parens the type annotation wins over class_reference.
        subst.contains = default_contains
        params.contains = [param_type_annotation] + base_contains

        Highlight::Mode.new.apply(
          name: "Crystal",
          aliases: ["cr"],
          keywords: keywords,
          contains: ([hljs.shebang(binary: "crystal")] of Highlight::Mode) + default_contains
        )
      end
    end
  end
end

fn = ->(hljs : Highlight::HLJS) { Kodkod::Syntax::Grammars.crystal(hljs) }
Highlight::Languages.register("crystal", fn)
Highlight::HLJS.default.register_language("crystal", fn)
