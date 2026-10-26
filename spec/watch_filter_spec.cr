require "spec"
require "file_utils"
require "../src/watch_filter"

def with_temp_dir(& : String ->)
  dir = File.join(Dir.tempdir,
    "kodkod-spec-#{Random.new.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_r(dir) rescue nil
  end
end

describe Kodkod::WatchFilter do
  # The predicate is consulted on the directory ENTRY being armed;
  # pruning everything beneath a skipped directory is the walk's job
  # (a skipped parent is never descended into).
  it "skips hidden directories regardless of gitignore" do
    with_temp_dir do |dir|
      Kodkod::WatchFilter.skip?(dir, File.join(dir, ".git")).should be_true
      Kodkod::WatchFilter.skip?(dir, File.join(dir, ".cache")).should be_true
      Kodkod::WatchFilter.skip?(dir,
        File.join(dir, "src", ".vscode")).should be_true
    end
  end

  it "skips root-gitignored directories at any depth" do
    with_temp_dir do |dir|
      File.write(File.join(dir, ".gitignore"), "node_modules/\nbuild\n")
      Kodkod::WatchFilter.skip?(dir, File.join(dir, "node_modules")).should be_true
      Kodkod::WatchFilter.skip?(dir,
        File.join(dir, "src", "node_modules")).should be_true
      Kodkod::WatchFilter.skip?(dir, File.join(dir, "build")).should be_true
    end
  end

  it "keeps regular subtrees and the root itself" do
    with_temp_dir do |dir|
      File.write(File.join(dir, ".gitignore"), "node_modules/\n")
      Kodkod::WatchFilter.skip?(dir, dir).should be_false
      Kodkod::WatchFilter.skip?(dir, File.join(dir, "src")).should be_false
      Kodkod::WatchFilter.skip?(dir,
        File.join(dir, "src", "node_modules.rb")).should be_false
    end
  end
end
