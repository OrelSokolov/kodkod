# kodkod — Syntax::Palette: scope names → colors, GitHub Light/Dark
# (github-vscode-theme values). Lookup is longest-prefix: an exact
# "title.function" wins, "title.function.invoke" falls back to
# "title". nil scope and unknown scopes → nil (the default text
# color).

require "egui-cr/egui"

module Kodkod
  module Syntax
    module Palette
      DARK = {
        "keyword"            => Egui::Color32.rgb(0xff, 0x7b, 0x72),
        "built_in"           => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "builtin"            => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "type"               => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "literal"            => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "number"             => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "string"             => Egui::Color32.rgb(0xa5, 0xd6, 0xff),
        "char.escape"        => Egui::Color32.rgb(0x7e, 0xe7, 0x87),
        "escape"             => Egui::Color32.rgb(0x7e, 0xe7, 0x87),
        "regexp"             => Egui::Color32.rgb(0x7e, 0xe7, 0x87),
        "subst"              => Egui::Color32.rgb(0xa5, 0xd6, 0xff),
        "symbol"             => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "class"              => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "title"              => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "title.function"     => Egui::Color32.rgb(0xd2, 0xa8, 0xff),
        "function"           => Egui::Color32.rgb(0xd2, 0xa8, 0xff),
        "params"             => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "comment"            => Egui::Color32.rgb(0x8b, 0x94, 0x9e),
        "doctag"             => Egui::Color32.rgb(0xff, 0x7b, 0x72),
        "meta"               => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "section"            => Egui::Color32.rgb(0x1f, 0x6f, 0xeb),
        "tag"                => Egui::Color32.rgb(0x7e, 0xe7, 0x87),
        "name"               => Egui::Color32.rgb(0x7e, 0xe7, 0x87),
        "attr"               => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "attribute"          => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "variable"           => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "variable.language"  => Egui::Color32.rgb(0xff, 0x7b, 0x72),
        "operator"           => Egui::Color32.rgb(0xff, 0x7b, 0x72),
        "punctuation"        => Egui::Color32.rgb(0xc9, 0xd1, 0xd9),
        "property"           => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "bullet"             => Egui::Color32.rgb(0xff, 0xa6, 0x57),
        "code"               => Egui::Color32.rgb(0x79, 0xc0, 0xff),
        "emphasis"           => Egui::Color32.rgb(0xc9, 0xd1, 0xd9),
        "strong"             => Egui::Color32.rgb(0xc9, 0xd1, 0xd9),
        "link"               => Egui::Color32.rgb(0xa5, 0xd6, 0xff),
        "quote"              => Egui::Color32.rgb(0x8b, 0x94, 0x9e),
        "selector-tag"       => Egui::Color32.rgb(0xff, 0x7b, 0x72),
        "selector-id"        => Egui::Color32.rgb(0xd2, 0xa8, 0xff),
        "selector-class"     => Egui::Color32.rgb(0xff, 0xa6, 0x57),
      }

      LIGHT = {
        "keyword"            => Egui::Color32.rgb(0xcf, 0x22, 0x2e),
        "built_in"           => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "builtin"            => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "type"               => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "literal"            => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "number"             => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "string"             => Egui::Color32.rgb(0x0a, 0x30, 0x69),
        "char.escape"        => Egui::Color32.rgb(0x11, 0x63, 0x29),
        "escape"             => Egui::Color32.rgb(0x11, 0x63, 0x29),
        "regexp"             => Egui::Color32.rgb(0x11, 0x63, 0x29),
        "subst"              => Egui::Color32.rgb(0x0a, 0x30, 0x69),
        "symbol"             => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "class"              => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "title"              => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "title.function"     => Egui::Color32.rgb(0x82, 0x50, 0xdf),
        "function"           => Egui::Color32.rgb(0x82, 0x50, 0xdf),
        "params"             => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "comment"            => Egui::Color32.rgb(0x57, 0x60, 0x6a),
        "doctag"             => Egui::Color32.rgb(0xcf, 0x22, 0x2e),
        "meta"               => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "section"            => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "tag"                => Egui::Color32.rgb(0x11, 0x63, 0x29),
        "name"               => Egui::Color32.rgb(0x11, 0x63, 0x29),
        "attr"               => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "attribute"          => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "variable"           => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "variable.language"  => Egui::Color32.rgb(0xcf, 0x22, 0x2e),
        "operator"           => Egui::Color32.rgb(0xcf, 0x22, 0x2e),
        "punctuation"        => Egui::Color32.rgb(0x24, 0x29, 0x2f),
        "property"           => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "bullet"             => Egui::Color32.rgb(0x95, 0x38, 0x00),
        "code"               => Egui::Color32.rgb(0x05, 0x50, 0xae),
        "emphasis"           => Egui::Color32.rgb(0x24, 0x29, 0x2f),
        "strong"             => Egui::Color32.rgb(0x24, 0x29, 0x2f),
        "link"               => Egui::Color32.rgb(0x0a, 0x30, 0x69),
        "quote"              => Egui::Color32.rgb(0x57, 0x60, 0x6a),
        "selector-tag"       => Egui::Color32.rgb(0x11, 0x63, 0x29),
        "selector-id"        => Egui::Color32.rgb(0x82, 0x50, 0xdf),
        "selector-class"     => Egui::Color32.rgb(0x95, 0x38, 0x00),
      }

      def self.color(scope : String?, dark : Bool) : Egui::Color32?
        return nil unless scope
        table = dark ? DARK : LIGHT
        return table[scope]? || begin
          # Longest-prefix fallback: "title.function.invoke" →
          # "title.function" → "title".
          parts = scope.split('.')
          (parts.size - 1).downto(1) do |n|
            if (c = table[parts[0...n].join('.')]?)
              return c
            end
          end
          nil
        end
      end
    end
  end
end
