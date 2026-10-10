# kodkod — a code editor (VSCode/Zed-like) on egui-cr:
# a rope buffer for huge files, syntax highlighting via the
# highlight.cr shard (a port of the highlight.js engine),
# a lazy FileTree explorer, and basic VIM modal editing.

require "egui-cr/egui"
require "egui-cr/egui/backend/sokol"

require "./rope"
require "./syntax"
require "./editor_buffer"
require "./code_editor"
require "./vim_command"
require "./file_tree"
require "./file_viewer"
require "./fuzzy"
require "./quick_open"
require "./vim_mode"
require "./app"

# Entry point: the framework CLI parse pulls --page out of ARGV (in
# place — the file arguments left over go to the app).
cli = Egui::CLI.parse(ARGV)
# `--theme Dark|Light` and `--dir PATH` — run overrides pulled out of
# the file list before the app sees it.
theme = nil
# Default the workspace to the directory kodkod was launched from;
# `--dir PATH` overrides it.
dir = Dir.current
files = [] of String
argv = cli[:argv].dup
argv.each_with_index do |arg, i|
  if arg == "--theme" && (value = argv[i + 1]?)
    theme = value
  elsif argv[i - 1]? == "--theme"
    next
  elsif arg == "--dir" && (value = argv[i + 1]?)
    dir = value
  elsif argv[i - 1]? == "--dir"
    next
  else
    files << arg
  end
end
# Monospace face for code: the editor, the ':' command line and inline
# code all paint through the "monospace" family (Context#mono_fonts).
# Hack — the FIRST face of upstream egui's Monospace family — shipped
# in the egui.cr checkout, then the system mono fallbacks (the same
# chain as h2term); without one the app font serves code — degraded
# (proportional advances) but functional.
EGUI_FONTS = File.expand_path(
  "../../egui.cr/egui-upstream/crates/epaint_default_fonts/fonts", __DIR__)

SYSTEM_MONO = [
  "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
  "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
  "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
  "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
  "/System/Library/Fonts/SFMono-Regular.ttf",
  "/System/Library/Fonts/SFNSMono.ttf",
  "/Library/Fonts/JetBrainsMono-Regular.ttf",
]

def pick_monospace : Nil
  candidates = [
    "#{EGUI_FONTS}/Hack-Regular.ttf", # upstream's terminal face
  ] + SYSTEM_MONO

  font = Egui::Backend::Sokol.fonts_from_system(candidates)
  if font
    if (faces = font.as?(Egui::Backend::CrystalFonts))
      STDERR.puts "kodkod: mono font faces: #{faces.face_paths.join(" -> ")}"
    end
    Egui::Backend::Sokol.register_font("monospace", font)
  end
end

pick_monospace

app = KodkodApp.new(files, dir, theme)
if (route = cli[:route])
  app.ctx.router.navigate(route)
end
Egui::Backend::Sokol.run(app,
  title: "kodkod", width: 1200, height: 800,
  decorations: false, inspector: :hidden)
