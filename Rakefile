require "fileutils"
require "etc"

# kodkod builds on top of egui-cr as a (path) shard dependency. The
# native static library (sokol_app/gfx/gl + fontstash + nanosvg + pty
# shims) lives in the egui.cr checkout — build it there if missing.
EGUI_DIR = File.expand_path(ENV.fetch("EGUI_DIR", File.expand_path("../egui.cr", __dir__)))
WINDOWS  = Gem.win_platform?
DARWIN   = RUBY_PLATFORM.include?("darwin")
NATIVE_LIB = WINDOWS ? "lib/egui_cr_sokol.lib" : "lib/libegui_cr_sokol.a"

desc "Ensure the egui-cr native library exists (runs its build:native once)"
task "build:native" do
  lib = File.join(EGUI_DIR, NATIVE_LIB)
  next if File.exist?(lib)
  puts "▶ native lib missing — building in #{EGUI_DIR}"
  system("rake", "build:native", chdir: EGUI_DIR) or
    abort("rake build:native failed in #{EGUI_DIR}")
end

def link_flags
  libdir = File.join(EGUI_DIR, "lib")
  flag = WINDOWS ? "/LIBPATH:#{libdir}" : "-L#{libdir}"
  if DARWIN
    ft_libs = %x{pkg-config --libs-only-L freetype2 2>/dev/null}.strip
    ft_libs = "-L/opt/homebrew/lib" if ft_libs.empty?
    flag = "#{flag} #{ft_libs} -framework Cocoa -framework OpenGL -framework QuartzCore"
  end
  flag
end

def build_app(opt_flags, label)
  FileUtils.mkdir_p("bin")
  puts "▶ crystal build kodkod (#{label})"
  cmd = "crystal build src/kodkod.cr -o bin/kodkod #{opt_flags}--link-flags \"#{link_flags}\""
  system(cmd) or abort("build failed")
end

desc "Build bin/kodkod without --release (fast iteration; OPT=-O3 for optimized)"
task "build:dev" => ["build:native"] do
  opt = ENV.fetch("OPT", "").strip
  build_app(opt.empty? ? "" : "#{opt} ", opt.empty? ? "dev" : "dev #{opt}")
end

desc "Build bin/kodkod with --release (shipped binary)"
task "build:release" => ["build:native"] do
  build_app("--release ", "release")
end

desc "Run the spec suite (headless — no GPU needed)"
task :spec do
  sh "crystal spec"
end

task default: ["build:dev"]
