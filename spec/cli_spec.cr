require "spec"
require "../src/cli"

describe Kodkod::CLIOptions do
  it "collects positional arguments as files" do
    o = Kodkod::CLIOptions.parse(["a.cr", "b.json"])
    o.files.should eq(["a.cr", "b.json"])
    o.theme.should be_nil
    o.dir.should eq(Dir.current)
    o.error.should be_nil
    o.help?.should be_false
    o.version?.should be_false
  end

  it "parses --theme and --dir with both flag forms" do
    o = Kodkod::CLIOptions.parse(["--theme", "Light", "--dir=/tmp"])
    o.theme.should eq("Light")
    o.dir.should eq("/tmp")
    o = Kodkod::CLIOptions.parse(["--theme=Dark", "--dir", "/etc"])
    o.theme.should eq("Dark")
    o.dir.should eq("/etc")
  end

  it "rejects unknown themes and options" do
    Kodkod::CLIOptions.parse(["--theme", "Neon"]).error.should_not be_nil
    Kodkod::CLIOptions.parse(["--neon"]).error.should eq("unknown option --neon")
  end

  it "flags --help and --version" do
    Kodkod::CLIOptions.parse(["--help"]).help?.should be_true
    Kodkod::CLIOptions.parse(["-h"]).help?.should be_true
    Kodkod::CLIOptions.parse(["--version"]).version?.should be_true
    # The help text documents every option the binary understands.
    help = Kodkod::CLIOptions.parse([] of String).help_text
    {"--theme", "--dir", "--page", "--help", "--version"}.each do |flag|
      help.should contain(flag)
    end
  end

  it "stops option parsing after -- (dash-prefixed filenames)" do
    o = Kodkod::CLIOptions.parse(["--", "-weird-name.cr", "plain.txt"])
    o.error.should be_nil
    o.files.should eq(["-weird-name.cr", "plain.txt"])
  end
end
