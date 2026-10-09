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
app = KodkodApp.new(files, dir, theme)
if (route = cli[:route])
  app.ctx.router.navigate(route)
end
Egui::Backend::Sokol.run(app,
  title: "kodkod", width: 1200, height: 800,
  decorations: false, inspector: :hidden)
