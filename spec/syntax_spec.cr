require "spec"
require "../src/syntax"

def tokens_join(tokens : Array(Kodkod::Syntax::Token)) : String
  tokens.map(&.text).join
end

def token_with(tokens : Array(Kodkod::Syntax::Token), text : String)
  tokens.find { |t| t.text == text }
end

describe Kodkod::Syntax do
  it "returns nil for unknown languages" do
    Kodkod::Syntax.highlight("x = 1", "no-such-lang").should be_nil
  end

  it "aliases resolve to the same engine" do
    Kodkod::Syntax["js"].should eq(Kodkod::Syntax["javascript"])
    Kodkod::Syntax["sh"].should eq(Kodkod::Syntax["bash"])
    Kodkod::Syntax["yml"].should eq(Kodkod::Syntax["yaml"])
  end

  describe "coverage invariant (tokens.join == source)" do
    crystal_sample = <<-CRYSTAL
      # a comment
      require "json"

      module Kodkod
        VERSION = "0.1.0"

        def self.parse(text : String, & : Int32 ->) : Nil
          count = 0_i64
          text.each_line do |line|
            count += 1 if line.includes?('#')
          end
          yield count
        end
      end

      puts Kodkod::VERSION
      x = :symbol
      y = @instance_var
      z = 42 + 3.14 + 0xff
      re = /hello\#{x}/mi
      s = <<~HEREDOC
        text \#{x}
      HEREDOC
      CRYSTAL
    json_sample = %q({
      "name": "kodkod",
      "version": 0.1,
      "tags": ["editor", "crystal"],
      "config": { "vim": true, "tabs": null }
    })
    bash_sample = <<-BASH
      #!/usr/bin/env bash
      # build it
      set -euo pipefail
      NAME="kodkod"
      if [ "$#" -gt 0 ]; then
        echo "building $NAME ($1)"
        cd src && crystal build kodkod.cr
      fi
      BASH
    yaml_sample = <<-YAML
      # config
      name: kodkod
      version: 0.1.0
      vim:
        enabled: true
        counts: 3
      tags:
        - editor
        - crystal
      YAML
    js_sample = <<-JS
      // config loader
      const defaults = { vim: true, count: 10 };
      function load(name = "kodkod") {
        /* merge */
        return { ...defaults, name, n: 0xff + 1.5e3 };
      }
      let s = `template ${name} string`;
      export default load;
      JS
    samples = {
      "crystal"    => crystal_sample,
      "json"       => json_sample,
      "bash"       => bash_sample,
      "yaml"       => yaml_sample,
      "javascript" => js_sample,
    }

    samples.each do |lang, code|
      it "covers #{lang}" do
        tokens = Kodkod::Syntax.highlight(code, lang).not_nil!
        tokens_join(tokens).should eq(code)
      end
    end
  end

  describe "golden scopes" do
    it "classifies crystal keywords, comments, strings, symbols, numbers" do
      code = "def parse # comment\n" \
             "  s = \"str\"\n" \
             "  sym = :ok\n" \
             "  n = 42\n" \
             "end\n"
      tokens = Kodkod::Syntax.highlight(code, "crystal").not_nil!
      token_with(tokens, "def").not_nil!.scope.should eq("keyword")
      token_with(tokens, "end").not_nil!.scope.should eq("keyword")
      token_with(tokens, "# comment").not_nil!.scope.should eq("comment")
      token_with(tokens, "\"str\"").not_nil!.scope.should eq("string")
      token_with(tokens, ":ok").not_nil!.scope.should eq("symbol")
      token_with(tokens, "42").not_nil!.scope.should eq("number")
    end

    it "paints crystal like ruby (shared constructs, same scopes)" do
      code = "class Foo < Bar\n  def run\n    self\n  end\nend\ny = Camel.new(1)\n"
      crystal_toks = Kodkod::Syntax.highlight(code, "crystal").not_nil!
      ruby_toks = Kodkod::Syntax.highlight(code, "ruby").not_nil!
      {"class"  => "keyword",
       "Foo"    => "title.class",
       "Bar"    => "title.class.inherited",
       "def"    => "keyword",
       "run"    => "title.function",
       "self"   => "variable.language",
       "end"    => "keyword",
       "Camel"  => "title.class",
       "1"      => "number"}.each do |word, scope|
        token_with(crystal_toks, word).not_nil!.scope.should eq(scope)
        token_with(ruby_toks, word).not_nil!.scope.should eq(scope)
      end
    end

    it "classifies json keys, strings, numbers, literals" do
      code = %q({"a": "b", "n": 3, "t": true, "f": null})
      tokens = Kodkod::Syntax.highlight(code, "json").not_nil!
      token_with(tokens, "\"a\"").not_nil!.scope.should eq("attr")
      token_with(tokens, "\"b\"").not_nil!.scope.should eq("string")
      token_with(tokens, "3").not_nil!.scope.should eq("number")
      # highlight.js nests literal > keyword around true/false/null; the
      # flat token carries the nearest scope, "keyword".
      token_with(tokens, "true").not_nil!.scope.should eq("keyword")
      token_with(tokens, "null").not_nil!.scope.should eq("keyword")
    end

    it "classifies bash comments, strings, variables, shebang" do
      code = "#!/bin/bash\n# note\nV=\"x\"\necho $V\n"
      tokens = Kodkod::Syntax.highlight(code, "bash").not_nil!
      token_with(tokens, "#!/bin/bash").not_nil!.scope.should eq("meta")
      token_with(tokens, "# note").not_nil!.scope.should eq("comment")
      token_with(tokens, "\"x\"").not_nil!.scope.should eq("string")
      token_with(tokens, "$V").not_nil!.scope.should eq("variable")
    end

    it "classifies yaml keys, strings, numbers" do
      code = "name: kodkod\nvim: \"on\"\ncount: 3\n"
      tokens = Kodkod::Syntax.highlight(code, "yaml").not_nil!
      token_with(tokens, "name:").not_nil!.scope.should eq("attr")
      token_with(tokens, "\"on\"").not_nil!.scope.should eq("string")
      token_with(tokens, "3").not_nil!.scope.should eq("number")
    end

    it "classifies javascript keywords, comments, template strings" do
      code = "const x = 1; // hi\nlet s = `t`;\n"
      tokens = Kodkod::Syntax.highlight(code, "javascript").not_nil!
      token_with(tokens, "const").not_nil!.scope.should eq("keyword")
      token_with(tokens, "// hi").not_nil!.scope.should eq("comment")
      token_with(tokens, "`t`").not_nil!.scope.should eq("string")
      token_with(tokens, "1").not_nil!.scope.should eq("number")
    end

    it "classifies gitignore comments, negations, globs, escapes" do
      code = "# build artifacts\n" \
             "*.o\n" \
             "!important.log\n" \
             "\\#notes\n" \
             "**/logs\n" \
             "[ab]/*.tmp\n"
      tokens = Kodkod::Syntax.highlight(code, "gitignore").not_nil!
      token_with(tokens, "# build artifacts").not_nil!.scope.should eq("comment")
      token_with(tokens, "!").not_nil!.scope.should eq("keyword")
      token_with(tokens, "*").not_nil!.scope.should eq("regexp")
      token_with(tokens, "**").not_nil!.scope.should eq("regexp")
      token_with(tokens, "\\#").not_nil!.scope.should eq("char.escape")
      tokens_join(tokens).should eq(code)
    end

    it "resolves the gitignore alias" do
      Kodkod::Syntax["ignore"].should eq(Kodkod::Syntax["gitignore"])
    end
  end

  it "maps scopes to palette colors with prefix fallback" do
    Kodkod::Syntax::Palette.color("keyword", true).should_not be_nil
    Kodkod::Syntax::Palette.color(nil, true).should be_nil
    Kodkod::Syntax::Palette.color("title.function", false)
      .should eq(Kodkod::Syntax::Palette::LIGHT["title.function"])
    # longest-prefix fallback
    Kodkod::Syntax::Palette.color("title.function.invoke", false)
      .should eq(Kodkod::Syntax::Palette::LIGHT["title.function"])
    # light and dark differ for the same scope
    Kodkod::Syntax::Palette.color("keyword", true)
      .should_not eq(Kodkod::Syntax::Palette.color("keyword", false))
  end

  it "highlights a large file in reasonable time" do
    chunk = "def foo(bar : Int32) : String\n" \
            "  # comment line\n" \
            "  x = \"quoted \#{bar}\" + :sym + 123\n" \
            "end\n"
    code = chunk * 500 # ~60 KB
    t0 = Time.monotonic
    tokens = Kodkod::Syntax.highlight(code, "crystal").not_nil!
    elapsed = Time.monotonic - t0
    tokens_join(tokens).should eq(code)
    elapsed.total_seconds.should be < 5.0 # generous bound for a debug build
  end
end

describe "Crystal %-literals" do
  it "tokenizes %w[] word arrays as strings" do
    toks = Kodkod::Syntax.highlight(<<-CRYSTAL, "crystal").not_nil!
      words = %w[
        def end if
      ]
    CRYSTAL
    # The words inside the literal are ONE string token run — not
    # keywords. Join coverage still holds (checked by the invariant
    # above for the general case).
    strings = toks.select { |t| t.scope == "string" }
    strings.map(&.text).join.should contain("def end if")
    toks.select { |t| t.scope == "keyword" }.map(&.text.strip)
      .should_not contain("def")
  end

  it "handles the paired and same-char delimiters" do
    {% for pair in {"%w(one two)", "%i[one]", "%q{one}", "%Q<one>", "%(one)", "%r|one|"} %}
      toks = Kodkod::Syntax.highlight({{ pair }} + "\n", "crystal").not_nil!
      toks.any? { |t| t.text.includes?("one") && %w[string regexp].includes?(t.scope) }
        .should be_true
    {% end %}
  end
end

describe "Crystal string interpolation" do
  it "tokenizes code inside #{...} as code, not string" do
    # The user-facing symptom this pins down: everything inside #{...}
    # used to paint in the string color. The token stream itself is
    # correct (matches the highlight.js Ruby oracle): plain code inside
    # the interpolation carries the "subst" scope, nested literals keep
    # their own scopes.
    toks = Kodkod::Syntax.highlight(
      "ui.label(\"FPS: \#{\"%.1f\" % ctx.fps} (\#{x * 1000})\")\n",
      "crystal"
    ).not_nil!
    tokens_join(toks).should eq("ui.label(\"FPS: \#{\"%.1f\" % ctx.fps} (\#{x * 1000})\")\n")
    toks.find { |t| t.text == "\"%.1f\"" }.try(&.scope).should eq("string")
    toks.find { |t| t.text == "1000" }.try(&.scope).should eq("number")
    toks.find { |t| t.text.starts_with?("\#{") }.try(&.scope).should eq("subst")
    # keywords stay keywords inside an interpolation
    toks = Kodkod::Syntax.highlight("\"v: \#{if true then 1 else 2 end}\"\n", "crystal").not_nil!
    %w[if then else end].each do |kw|
      toks.find { |t| t.scope == "keyword" && t.text == kw }.should_not be_nil
    end
  end

  it "paints interpolated code in the default text color" do
    # GitHub-theme behavior: .hljs-subst has no color of its own, so
    # #{...} code renders like ordinary code, not like the string.
    Kodkod::Syntax::Palette.color("subst", true).should be_nil
    Kodkod::Syntax::Palette.color("subst", false).should be_nil
  end
end
