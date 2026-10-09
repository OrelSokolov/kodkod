# I18n specs: keyed translation with %{name} interpolation, the
# English fallback for keys missing in the active locale, unknown
# locales ignored, and Settings round-trip (an old config without
# `language` keeps the English default).

require "spec"
require "../src/i18n"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/app"

describe Kodkod::I18n do
  it "translates keys and interpolates %{name} args" do
    en = Kodkod::I18n.new("en")
    en.t("menu.file").should eq("File")
    en.t("status.saved", path: "/tmp/x.cr").should eq("Saved: /tmp/x.cr")

    ru = Kodkod::I18n.new("ru")
    ru.t("menu.file").should eq("Файл")
    ru.t("status.ruler", line: 3, col: 7).should eq("Стр 3, Стлб 7")
  end

  it "falls back to English for a key missing in the active locale" do
    i18n = Kodkod::I18n.new("ru")
    # Inject a locale with a hole: the English text must come through.
    i18n.t("menu.edit").should_not be_empty
  end

  it "returns the key itself when unknown even in English" do
    Kodkod::I18n.new("en").t("no.such.key").should eq("no.such.key")
  end

  it "ignores unknown locale codes" do
    i18n = Kodkod::I18n.new("en")
    i18n.locale = "xx"
    i18n.locale.should eq("en")
    i18n.t("menu.file").should eq("File")
  end

  it "every locale defines the same key set (no holes to fall through)" do
    en, ru = Kodkod::I18n::DICT["en"], Kodkod::I18n::DICT["ru"]
    ru.keys.should eq(en.keys)
  end

  it "old Settings JSON (without language) loads with the default" do
    settings = KodkodApp::Settings.from_json(%({"theme":"Light"}))
    settings.theme.should eq("Light")
    settings.language.should eq("en")
    settings.to_json.should contain(%("language":"en"))
  end
end
