# kodkod — Syntax facade over the highlight.cr shard (a 1:1 port of
# the highlight.js 11.12.0 engine): 37 common languages come from the
# shard's registry; the Crystal grammar lives here and registers into
# the shard's default HLJS instance at require time. The palette
# (scope → egui color) stays kodkod's own.

require "highlight_cr"
require "./syntax/palette"
require "./syntax/grammars/crystal"

module Kodkod
  module Syntax
    struct Token
      getter scope : String?
      getter text : String

      def initialize(@scope : String?, @text : String)
      end
    end

    # The language registered in the shard's HLJS registry (aliases
    # resolve to the same Mode object); nil for unknown languages.
    def self.[](name : String) : Highlight::Mode?
      Highlight::HLJS.default.get_language(name)
    end

    # Flat (scope, text) tokens for `lang`; nil when the language is
    # unknown — callers degrade to plain rendering.
    def self.highlight(code : String, lang : String) : Array(Token)?
      Highlight.tokens(code, lang).try &.map { |t| Token.new(t[0], t[1]) }
    end

    # Whether an identifier inside a token of this scope may still be
    # a definition REFERENCE (the editor's Ctrl-link layer): prose
    # scopes — comments, strings, regexps, quotes — are not code, and
    # indexed words found there were the mass false positives of the
    # underline-everything scan. nil scope (plain identifiers) and
    # code scopes stay linkable.
    def self.linkable_scope?(scope : String?) : Bool
      return true if scope.nil?
      head = scope.split('.').first
      !{"comment", "string", "quote", "doctag", "regexp",
        "subst", "escape"}.includes?(head)
    end
  end
end
