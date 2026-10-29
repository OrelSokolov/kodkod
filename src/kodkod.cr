# kodkod — a code editor (VSCode/Zed-like) on egui-cr:
# a rope buffer for huge files, syntax highlighting via the
# highlight.cr shard (a port of the highlight.js engine),
# a lazy FileTree explorer, and basic VIM modal editing.

require "egui-cr/egui"
require "egui-cr/egui/backend/sokol"

require "./rope"
require "./syntax"
require "./editor_buffer"
require "./fold_map"
require "./code_editor"
require "./vim_command"
require "./file_tree"
require "./file_viewer"
require "./about"
require "./fuzzy"
require "./quick_open"
require "./vim_mode"
require "./voice/service"
require "./voice/page"
require "./app"
require "./cli"
require "./index_worker"

# The indexer sidecar: the app re-execs itself with --index-worker to
# run the project walk + extraction in a SEPARATE process (single
# threaded scheduler + Boehm GC — see src/index_worker.cr). Branch
# BEFORE any sokol/egui init: the child stays headless and talks
# line-JSON over stdin/stdout.
if ARGV.includes?("--index-worker")
  Kodkod::IndexWorker.run(STDIN, STDOUT, ->KodkodApp.lang_for(String))
  exit
end

# Entry point: the framework CLI parse pulls --page out of ARGV (in
# place — the file arguments left over go to the app).
cli = Egui::CLI.parse(ARGV)
# Standard OptionParser over the rest: --theme/--dir overrides plus
# --help/--version (src/cli.cr). Positional arguments are files
# opened in tabs at startup.
opts = Kodkod::CLIOptions.parse(cli[:argv])
if (msg = opts.error)
  STDERR.puts "kodkod: #{msg}"
  STDERR.puts opts.help_text
  exit 1
end
if opts.help?
  puts opts.help_text
  exit
end
if opts.version?
  puts "kodkod #{Kodkod::VERSION}"
  exit
end
theme = opts.theme
# Default the workspace to the directory kodkod was launched from;
# `--dir PATH` overrides it.
dir = opts.dir
files = opts.files
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
  # The taskbar/window icon (Win32; see app_icon.cr for the tints).
  icon: Kodkod.icon_rgba(light: false),
  decorations: false, inspector: :hidden)
