require "spec"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/app"

# Exposes the private lang detection for direct assertions.
class LangDetectTestApp < KodkodApp
  def lang_for(path : String) : String?
    super
  end
end

describe "language detection" do
  it "maps extensions to registered languages" do
    KodkodApp::LANG_BY_EXT.each do |ext, lang|
      Kodkod::Syntax[lang].should_not be_nil,
        "LANG_BY_EXT maps #{ext} to unregistered language #{lang}"
    end
  end

  it "maps well-known filenames to registered languages" do
    KodkodApp::LANG_BY_NAME.each do |name, lang|
      Kodkod::Syntax[lang].should_not be_nil,
        "LANG_BY_NAME maps #{name} to unregistered language #{lang}"
    end
  end

  it "detects by extension" do
    app = LangDetectTestApp.new([] of String)
    app.lang_for("view.erb").should eq("erb")
    app.lang_for("app.cjs").should eq("javascript")
    app.lang_for("viewController.mm").should eq("objectivec")
    app.lang_for("page.phtml").should eq("php-template")
    app.lang_for("build.mk").should eq("makefile")
    app.lang_for("api/users/index.json.jbuilder").should eq("ruby")
  end

  it "falls back to the basename for extensionless files" do
    app = LangDetectTestApp.new([] of String)
    app.lang_for("/home/x/Rakefile").should eq("ruby")
    app.lang_for("Gemfile").should eq("ruby")
    app.lang_for("Vagrantfile").should eq("ruby")
    app.lang_for("/build/dir/GNUmakefile").should eq("makefile")
    app.lang_for("makefile").should eq("makefile")
    app.lang_for("/proj/.gitignore").should eq("gitignore")
    app.lang_for("sub/dir/.gitignore").should eq("gitignore")
    app.lang_for("/app/Dockerfile").should eq("dockerfile")
    app.lang_for("Dockerfile").should eq("dockerfile")
    app.lang_for("Containerfile").should eq("dockerfile")
  end

  it "treats a Dockerfile stage suffix as part of the name" do
    app = LangDetectTestApp.new([] of String)
    app.lang_for("Dockerfile.dev").should eq("dockerfile")
    app.lang_for("docker/Dockerfile.prod").should eq("dockerfile")
    app.lang_for("Containerfile.base").should eq("dockerfile")
  end

  it "leaves unknown files plain" do
    app = LangDetectTestApp.new([] of String)
    app.lang_for("README").should be_nil
    app.lang_for("Gemfile.lock").should be_nil
    app.lang_for("data.bin").should be_nil
  end
end
