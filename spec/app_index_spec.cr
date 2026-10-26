require "spec"
require "file_utils"
require "../src/fuzzy"
require "../src/quick_open"
require "../src/app"

# Exposes the private index state for assertions.
class IndexTestApp < KodkodApp
  def index; @index; end
  def index_queue; @index_queue; end
  def status; @status; end

  # Autoindex is off by default — the test starts it by hand.
  def start_index!(folder : String) : Nil
    start_indexing(folder)
  end
end

ISCREEN = Egui::Rect.from_min_size(Egui::Pos2.zero,
  Egui::Vec2.new(1200.0, 800.0))

def index_frame(app : KodkodApp, ctx : Egui::Context,
                time : Float64 = 0.016) : Nil
  ctx.begin_frame(Egui::RawInput.new(ISCREEN, [] of Egui::Event, time))
  app.update(ctx)
  ctx.end_frame
end

describe "app project indexing" do
  it "indexes the workspace and serves the indexing page" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-app-idx-#{rand(1_000_000)}")
      FileUtils.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, "src", "app.cr"), "module Demo\n  def helper\n  end\nend\n")
      begin
        app = IndexTestApp.new([] of String, dir: root)
        app.start_index!(root)
        ctx = Egui::Context.new
        3.times { |i| index_frame(app, ctx, time: 0.016 * (i + 1)) }
        # Drain the worker fiber (cooperative: yield until idle).
        spins = 0
        while app.index_queue.busy? && spins < 20_000
          Fiber.yield
          spins += 1
        end
        index_frame(app, ctx, time: 0.1)
        app.index_queue.busy?.should be_false
        app.index.has_name?("helper").should be_true
        defs = app.index.lookup("helper")
        defs.size.should eq(1)
        defs.first.line.should eq(1)

        # The Indexing page renders without raising and resets nothing.
        ctx.router.navigate("root/indexing")
        2.times { |i| index_frame(app, ctx, time: 0.2 + i * 0.016) }
        app.index.has_name?("helper").should be_true
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end

# Exposes the jump machinery for focus assertions.
class JumpTestApp < KodkodApp
  def index; @index; end
  def index_queue; @index_queue; end
  def docs; @docs; end

  def jump(d : Kodkod::SymbolIndex::Def) : Nil
    jump_to(d)
  end

  def start_index!(folder : String) : Nil
    start_indexing(folder)
  end
end

describe "jump caret visibility" do
  it "focuses the editor after a jump into the ALREADY-ACTIVE tab" do
    Dir.tempdir.tap do |tmp|
      root = File.join(tmp, "kodkod-jump-#{rand(1_000_000)}")
      FileUtils.mkdir_p(root)
      path = File.join(root, "a.cr")
      File.write(path, "def helper\nend\n")
      begin
        app = JumpTestApp.new([path] of String, dir: root)
        app.start_index!(root)
        # Drain the worker fiber (cooperative: yield until idle).
        spins = 0
        while app.index_queue.busy? && spins < 20_000
          Fiber.yield
          spins += 1
        end
        ctx = Egui::Context.new
        3.times { |i| index_frame(app, ctx, time: 0.016 * (i + 1)) }
        # The file is the only (active) tab and its editor holds focus.
        fid = app.docs.first.focus_id.not_nil!
        ctx.memory.focus.id.should eq(
          Kodkod::CodeEditor.widget_id(fid))

        # Away to the Indexing page — focus drifts off the editor
        # (the page's own widgets). Then jump to a def in the SAME
        # tab: no tab change happens, so the caret would stay
        # unfocused without the pending-focus order.
        ctx.router.navigate("root/indexing")
        2.times { |i| index_frame(app, ctx, time: 0.1 + i * 0.016) }
        d = app.index.lookup("helper").first
        app.jump(d)
        ctx.router.back # the Indexing table does this after a jump
        3.times { |i| index_frame(app, ctx, time: 0.2 + i * 0.016) }
        ctx.memory.focus.id.should eq(
          Kodkod::CodeEditor.widget_id(fid))
        # And the caret sits on the definition line (1-based def line
        # 0 → "def helper").
        Kodkod::CodeEditor.cursor(ctx, app.docs.first.buffer?.not_nil!,
          fid).should eq({0, 4})
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
