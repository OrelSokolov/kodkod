require "fileutils"
require "etc"

# kodkod builds on top of egui-cr as a (github) shard dependency. The
# native static library (sokol_app/gfx/gl + fontstash + nanosvg + pty
# shims) lives in the egui.cr checkout installed by shards — build it
# there if missing.
EGUI_DIR = File.expand_path(ENV.fetch("EGUI_DIR", File.expand_path("lib/egui-cr", __dir__)))
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

# Real ImageMagick detection: IM7 ships `magick`, legacy 6.x only ships
# `convert` — whose version banner must actually say "ImageMagick" before
# the command is trusted (a same-named foreign binary proves nothing).
def imagemagick_command
  @imagemagick_command ||= ["magick", "convert"].find do |cmd|
    system("command -v #{cmd} >/dev/null 2>&1") &&
      %x{#{cmd} -version 2>&1}.to_s.scrub.match?(/ImageMagick/)
  end
end

# Render the SVG source once at a fixed density (4x the 96dpi natural
# size) so downscaling to the target sizes keeps crisp edges.
SVG_SOURCE = "assets/kodkod.svg"
SVG_RENDER = ["-background", "none", "-density", "384", SVG_SOURCE,
              "-gravity", "center"]

desc "Regenerate assets/kodkod.png and assets/kodkod.ico from the SVG source"
task :icons do
  magick = imagemagick_command
  abort "ImageMagick (magick/convert) is required to regenerate icons." unless magick
  abort "Source icon not found: #{SVG_SOURCE}" unless File.exist?(SVG_SOURCE)

  FileUtils.mkdir_p("assets")
  # Square raster icon (transparent padding keeps the 320:259 art ratio).
  sh "#{magick} #{SVG_RENDER.join(' ')} -resize 512x512 -extent 512x512 PNG32:assets/kodkod.png"
  # Multi-resolution Windows icon from the same render.
  sh "#{magick} #{SVG_RENDER.join(' ')} -resize 256x256 -extent 256x256 " \
     "-define icon:auto-resize=256,128,64,48,32,16 ICO:assets/kodkod.ico"

  # Window/caption icon rasters (straight RGBA8, 64×64): the art is
  # monochrome, baked in two tints — the caption slot follows the
  # theme (near-white art on the dark chrome and vice versa, see
  # KodkodApp#update); -colorize recolors the RGB channels while the
  # antialiased alpha edges stay as baked.
  { "dark" => "#202020", "light" => "#E8E8E8" }.each do |tint, hex|
    sh "#{magick} #{SVG_RENDER.join(' ')} -resize 64x64 -extent 64x64 " \
       "-fill '#{hex}' -channel RGB -colorize 100 RGBA:assets/icon_#{tint}.rgba"
  end

  # The packaging icons (crosspack picks the .ico up as the MSI
  # Add/Remove-Programs icon — the sibling of package.icon).
  FileUtils.mkdir_p("build")
  FileUtils.cp("assets/kodkod.png", "build/appicon.png")
  FileUtils.cp("assets/kodkod.ico", "build/appicon.ico")
end

# Everything the crosspack matrix step needs in build/bin: the
# release binary (named per host) — the fans-out into builds/ is
# crosspack's business (see crosspack.yml).
def build_artifacts
  Rake::Task["icons"].invoke
  Rake::Task["build:release"].invoke
  FileUtils.mkdir_p("build/bin")
  exe = WINDOWS ? "kodkod.exe" : "kodkod"
  # crystal build -o bin/kodkod yields bin/kodkod.exe on Windows.
  src = WINDOWS ? %w[kodkod.exe kodkod].map { |n| "bin/#{n}" }
                           .find { |p| File.exist?(p) } : "bin/kodkod"
  src or abort("build produced no binary in bin/")
  FileUtils.cp(src, "build/bin/#{exe}")
end

namespace :artifacts do
  desc "Build all linux/amd64 artifacts into build/bin (release kodkod)"
  task :linux do
    build_artifacts
  end

  desc "Build all windows/amd64 artifacts into build/bin (release kodkod)"
  task :windows do
    build_artifacts
  end

  desc "Build all darwin/arm64 artifacts into build/bin (release kodkod)"
  task :macos do
    build_artifacts
  end
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
