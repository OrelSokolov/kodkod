require "spec"
require "../src/symbol_extractor"

def hits_of(code : String, lang : String)
  Kodkod::SymbolExtractor.extract(code, lang)
    .map { |h| {h.name, h.kind, h.line} }
end

describe Kodkod::SymbolExtractor do
  it "extracts crystal defs, macros, classes and modules" do
    code = <<-CRYSTAL
      module Kodkod
        class App
          def initialize(@x)
          end

          private def helper? : Int32
            1
          end

          macro busted(name)
          end
        end

        class App::Inner
        end
      end
    CRYSTAL
    hits = hits_of(code, "crystal")
    hits.should contain({"Kodkod", :class, 0})
    hits.should contain({"App", :class, 1})
    hits.should contain({"initialize", :method, 2})
    hits.should contain({"helper?", :method, 5})
    hits.should contain({"busted", :macro, 9})
    # App::Inner — the nested-name rule catches the inner component.
    hits.should contain({"Inner", :class, 13})
  end

  it "extracts ruby defs and classes" do
    code = <<-RUBY
      class Foo
        def bar!(x)
        end
      end
      module Baz
      end
    RUBY
    hits = hits_of(code, "ruby")
    hits.should contain({"Foo", :class, 0})
    hits.should contain({"bar!", :method, 1})
    hits.should contain({"Baz", :class, 4})
  end

  it "does not match commented definitions" do
    hits = hits_of("# def commented\n  # class Nope\n", "ruby")
    hits.should be_empty
  end

  it "extracts python defs and classes" do
    code = <<-PY
      class A:
          def run(self):
              pass

          async def fetch(self):
              pass
    PY
    hits = hits_of(code, "python")
    hits.should contain({"A", :class, 0})
    hits.should contain({"run", :method, 1})
    hits.should contain({"fetch", :method, 4})
  end

  it "extracts go funcs and types" do
    code = <<-GO
      func main() {
      }

      func (s *Server) Start() error {
      }

      type Server struct {
      }

      type Reader interface {
      }
    GO
    hits = hits_of(code, "go")
    hits.should contain({"main", :function, 0})
    hits.should contain({"Start", :function, 3})
    hits.should contain({"Server", :type, 6})
    hits.should contain({"Reader", :type, 9})
  end

  it "extracts rust items" do
    code = <<-RUST
      pub fn visible() {}
      fn hidden() {}
      pub(crate) async unsafe fn wild() {}
      pub struct Config {}
      trait Sink {}
      mod inner {}
      macro_rules! bang {
      }
    RUST
    hits = hits_of(code, "rust")
    hits.should contain({"visible", :function, 0})
    hits.should contain({"hidden", :function, 1})
    hits.should contain({"wild", :function, 2})
    hits.should contain({"Config", :type, 3})
    hits.should contain({"Sink", :type, 4})
    hits.should contain({"inner", :module, 5})
    hits.should contain({"bang", :macro, 6})
  end

  it "extracts c macros, structs and functions" do
    code = <<-C
      #define MAX 10
      # define SPACED(x) ((x) + 1)
      struct node {
        int x;
      };
      int main(void) {
        return 0;
      }
      static inline int helper(int a) {
        return a;
      }
      // int commented_out(void) {
    C
    hits = hits_of(code, "c")
    hits.should contain({"MAX", :macro, 0})
    hits.should contain({"SPACED", :macro, 1})
    hits.should contain({"node", :type, 2})
    hits.should contain({"main", :function, 5})
    hits.should contain({"helper", :function, 8})
  end

  it "does not read control flow as c functions" do
    code = "int loop(int n) {\n  if (n > 0) {\n  }\n  while (n < 3) {\n  }\n  return 0;\n}\n"
    hits = hits_of(code, "c")
    hits.should contain({"loop", :function, 0})
    hits.should_not contain({"if", :function, 1})
    hits.should_not contain({"while", :function, 3})
  end

  it "extracts js/ts functions and classes" do
    code = <<-TS
      export function load(path) {}
      const arrow = (a, b) => a + b;
      const single = x => x;
      async function* gen() {}
      export class Widget {
      }
      interface Opts {}
    TS
    hits = hits_of(code, "typescript")
    hits.should contain({"load", :function, 0})
    hits.should contain({"arrow", :function, 1})
    hits.should contain({"single", :function, 2})
    hits.should contain({"gen", :function, 3})
    hits.should contain({"Widget", :class, 4})
    hits.should contain({"Opts", :type, 6})

    js = "function plain() {}\nclass Thing {}\n"
    hits_of(js, "javascript").should contain({"plain", :function, 0})
    hits_of(js, "javascript").should contain({"Thing", :class, 1})
  end

  it "extracts shell functions" do
    hits = hits_of("build_all() {\n  :\n}\n\nfunction nested() {\n}\n", "bash")
    hits.should contain({"build_all", :function, 0})
    hits.should contain({"nested", :function, 4})
  end

  it "reports the name's column, not the keyword's" do
    h = Kodkod::SymbolExtractor.extract("  def target\n", "ruby").first
    h.col.should eq(6)
    h = Kodkod::SymbolExtractor.extract("#define MAX 10\n", "c").first
    h.col.should eq(8)
  end

  it "returns nothing for unknown or nil languages" do
    Kodkod::SymbolExtractor.extract("def x", nil).should be_empty
    Kodkod::SymbolExtractor.extract("def x", "yaml").should be_empty
    Kodkod::SymbolExtractor.indexable?("crystal").should be_true
    Kodkod::SymbolExtractor.indexable?("yaml").should be_false
    Kodkod::SymbolExtractor.indexable?(nil).should be_false
  end
end

describe "SymbolExtractor token validation" do
  it "does not index def keywords inside %w[] literals" do
    # The real-world case: the crystal grammar's own keyword table —
    # `%w[\n  def end if ...\n]` — used to register a bogus "def end"
    # definition (the words keyword-ized as code before the grammar
    # grew %-literals, and the raw regex pass trusted them).
    code = "keywords[\"keyword\"] = %w[\n" \
           "  def end if elsif else unless while until for do then\n" \
           "]\n" \
           "def real_one\n" \
           "end\n"
    hits = hits_of(code, "crystal")
    hits.map(&.[0]).should_not contain("end")
    hits.map(&.[0]).should_not contain("if")
    hits.should contain({"real_one", :method, 3})
  end

  it "does not index definitions inside heredocs" do
    code = "text = <<-DOC\n" \
           "  def shadowed\n" \
           "DOC\n" \
           "def visible\n" \
           "end\n"
    hits = hits_of(code, "crystal")
    hits.map(&.[0]).should eq(["visible"])
  end

  it "does not index definitions inside ruby =begin/=end blocks" do
    code = "=begin\ndef documented\nend\n=end\ndef live\nend\n"
    hits = hits_of(code, "ruby")
    hits.map(&.[0]).should eq(["live"])
  end

  it "still indexes definitions when no grammar validates" do
    # Over the token cap the raw regex pass stands alone — a def is a
    # def, even if the prose filter cannot run.
    code = "def big\nend\n" + ("x" * Kodkod::SymbolExtractor::TOKEN_MAX_CHARS)
    hits = Kodkod::SymbolExtractor.extract(code, "crystal")
    hits.map(&.name).should contain("big")
  end
end

describe "SymbolExtractor keyword guard" do
  it "collects keyword sets from the registered grammars" do
    kw = Kodkod::SymbolExtractor.keywords_for("crystal").not_nil!
    {"def", "end", "if", "class"}.each { |w| kw.should contain(w) }
    # ruby's grammar models `def` as its own mode, not a keyword —
    # but `end` (what `def end` would hit) IS in its keyword list.
    Kodkod::SymbolExtractor.keywords_for("ruby").not_nil!
      .should contain("end")
    Kodkod::SymbolExtractor.keywords_for("no-such-lang").should be_nil
  end

  it "never indexes a keyword as a definition name" do
    # `def end` / `def def` — grammar samples and %w[] word tables
    # produce these; a keyword is never a valid method name, and the
    # guard holds even WITHOUT tokenization (huge files, quirky
    # heredocs) because it only consults the name itself.
    code = "def end\nend\ndef def\nend\ndef if\nend\ndef real\nend\n"
    hits = hits_of(code, "crystal")
    hits.map(&.[0]).should eq(["real"])

    code = "def end\nend\ndef live\nend\n"
    hits_of(code, "ruby").map(&.[0]).should eq(["live"])
  end

  it "stays clean on the project's own grammar and spec sources" do
    %w[src/syntax/grammars/crystal.cr spec/syntax_spec.cr].each do |f|
      hits = Kodkod::SymbolExtractor.extract(File.read(f), "crystal")
      # The files legitimately define modules/classes; the invariant
      # is that NO hit's name is a keyword.
      kw = Kodkod::SymbolExtractor.keywords_for("crystal").not_nil!
      hits.none? { |h| kw.includes?(h.name) }.should be_true
    end
  end
end

describe "SymbolExtractor constants" do
  it "extracts crystal constants, type aliases and enum members" do
    code = <<-CRYSTAL
      module Kodkod
        VERSION = "0.1.1"
        Config = NamedTuple(a: Int32)
        enum Color
          RED = 1
          GREEN
        end
        def helper
        end
        broken = X == 1
        count += 1
      end
    CRYSTAL
    hits = hits_of(code, "crystal")
    hits.should contain({"VERSION", :constant, 1})
    hits.should contain({"Config", :constant, 2})
    hits.should contain({"RED", :constant, 4})
    hits.should contain({"GREEN", :constant, 5})
    hits.should contain({"helper", :method, 7})
    # Comparisons (==) and op-assignments (+=) are not constants.
    hits.map(&.[0]).should_not contain("X")
    hits.map(&.[0]).should_not contain("count")
  end

  it "extracts ruby constants" do
    hits = hits_of("MAX = 10\nCount = Struct.new\nx = 1\n", "ruby")
    hits.should contain({"MAX", :constant, 0})
    hits.should contain({"Count", :constant, 1})
    hits.map(&.[0]).should_not contain("x")
  end

  it "extracts python UPPER_SNAKE constants only" do
    hits = hits_of("MAX_RETRIES = 3\nMixed = 2\nx = 1\n", "python")
    hits.should contain({"MAX_RETRIES", :constant, 0})
    hits.map(&.[0]).should_not contain("Mixed")
    hits.map(&.[0]).should_not contain("x")
  end

  it "extracts rust const and static items" do
    hits = hits_of("pub const MAX: Int32 = 10\nstatic mut COUNTER = 0\nconst fn f() {}\n", "rust")
    hits.should contain({"MAX", :constant, 0})
    hits.should contain({"COUNTER", :constant, 1})
    # const fn is a FUNCTION, not a constant.
    hits.should contain({"f", :function, 2})
  end

  it "extracts go consts and js/ts UPPER_SNAKE consts" do
    hits_of("const Pi = 3.14\n", "go").should contain({"Pi", :constant, 0})
    code = "export const API_URL = \"x\"\nconst arrow = (a) => a\n"
    hits = hits_of(code, "typescript")
    hits.should contain({"API_URL", :constant, 0})
    hits.should contain({"arrow", :function, 1})
  end

  it "extracts c enum members in both forms" do
    code = "enum color {\n  RED = 1,\n  GREEN,\n};\n"
    hits = hits_of(code, "c")
    hits.should contain({"RED", :constant, 1})
    hits.should contain({"GREEN", :constant, 2})
  end

  it "extracts java/csharp static finals" do
    code = "static final int MAX = 10;\nstatic final Map<String, String> CACHE = Map.of();\n"
    hits = hits_of(code, "java")
    hits.should contain({"MAX", :constant, 0})
    hits.should contain({"CACHE", :constant, 1})
  end

  it "does not index constants inside strings or comments" do
    code = "# MAX = 10\ns = \"MAX = 10\"\nMAX = 10\n"
    hits = hits_of(code, "crystal")
    hits.select { |h| h[2] == 2 }.should eq([{"MAX", :constant, 2}])
  end
end
