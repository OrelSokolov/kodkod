# kodkod — the application: a tabbed code editor (VSCode-like layout)
# on the framework's notepad skeleton: borderless window with tabs in
# the caption, routed pages (editor / settings / confirm-close), a
# lazy FileTree explorer in a resizable left panel, the rope-backed
# CodeEditor with syntax highlighting in the middle, a VIM modal layer
# over it, and a status bar (mode, Ln/Col, language, dirty state).

require "json"
require "mime"
require "./editor_buffer"
require "./code_editor"
require "./file_tree"
require "./file_viewer"
require "./about"
require "./app_icon"
require "./i18n"
require "./vim_command"
require "./vim_mode"

class KodkodApp < Egui::App
  enable_ecss "kodkod"

  class Settings
    include JSON::Serializable

    property theme : String = "Dark"
    property vim : Bool = true
    property show_hidden : Bool = false
    property show_explorer : Bool = true
    property cursor_blinks : Bool = true
    property syntax_highlight : Bool = true
    property language : String = "en"

    def initialize(@theme : String = "Dark", @vim : Bool = true,
                   @show_hidden : Bool = false,
                   @show_explorer : Bool = true,
                   @cursor_blinks : Bool = true,
                   @syntax_highlight : Bool = true,
                   @language : String = "en")
    end
  end

  THEMES = ["Dark", "Light"]

  # Extension → syntax registry name (Syntax.highlight key). Files
  # outside the map fall through to LANG_BY_NAME below.
  LANG_BY_EXT = {
    ".cr"  => "crystal", ".rb" => "ruby",
    ".rake" => "ruby", ".ru" => "ruby", ".gemspec" => "ruby",
    ".jbuilder" => "ruby",
    ".erb" => "erb",
    ".c"   => "c", ".h" => "c",
    ".cpp" => "cpp", ".hpp" => "cpp", ".cc" => "cpp",
    ".hh"  => "cpp", ".cxx" => "cpp", ".hxx" => "cpp",
    ".cs"  => "csharp",
    ".css" => "css", ".scss" => "scss", ".less" => "less",
    ".diff" => "diff", ".patch" => "diff",
    ".go"  => "go", ".graphql" => "graphql", ".gql" => "graphql",
    ".ini" => "ini", ".toml" => "ini",
    ".java" => "java", ".kt" => "kotlin", ".kts" => "kotlin",
    ".lua" => "lua", ".m" => "objectivec", ".mm" => "objectivec",
    ".pl"  => "perl", ".pm" => "perl",
    ".php" => "php", ".phtml" => "php-template",
    ".py"  => "python", ".pyi" => "python",
    ".r"   => "r", ".rs" => "rust",
    ".sql" => "sql", ".swift" => "swift", ".vb" => "vbnet",
    ".ts"  => "typescript", ".mts" => "typescript",
    ".wat" => "wasm",
    ".xml" => "xml", ".html" => "xml", ".htm" => "xml", ".svg" => "xml",
    ".xhtml" => "xml", ".xsl" => "xml", ".xsd" => "xml",
    ".rss" => "xml", ".atom" => "xml",
    ".json" => "json",
    ".yml" => "yaml", ".yaml" => "yaml",
    ".md"  => "markdown", ".markdown" => "markdown", ".mkd" => "markdown",
    ".mk"  => "makefile", ".mak" => "makefile",
    ".sh"  => "bash", ".bash" => "bash", ".zsh" => "bash",
    ".js"  => "javascript", ".mjs" => "javascript",
    ".cjs" => "javascript",
  }

  # Well-known extensionless filenames → syntax registry name. Matched
  # case-insensitively on the basename after LANG_BY_EXT misses.
  LANG_BY_NAME = {
    "makefile"     => "makefile",
    "gnumakefile"  => "makefile",
    "bsdmakefile"  => "makefile",
    "rakefile"     => "ruby",
    "gemfile"      => "ruby",
    "vagrantfile"  => "ruby",
  }

  TEXT_MIME_EXTRAS = {"application/json", "application/xml",
                      "application/yaml", "application/x-yaml",
                      "application/toml", "application/javascript",
                      # `file` reports an EMPTY file as inode/x-empty —
                      # it is still a perfectly editable text file.
                      "inode/x-empty"}

  # One open document: a rope buffer (text tab) or a FileViewer
  # (image tab), plus the text tab's STABLE widget focus id (an index
  # would shift on close and glue one document's caret onto
  # another's; image tabs take no focus).
  class Doc
    getter body : Kodkod::EditorBuffer | Kodkod::FileViewer
    getter focus_id : String?

    def initialize(@body : Kodkod::EditorBuffer, @focus_id : String)
    end

    def initialize(@body : Kodkod::FileViewer)
      @focus_id = nil
    end

    def buffer? : Kodkod::EditorBuffer?
      @body.as?(Kodkod::EditorBuffer)
    end

    def viewer? : Kodkod::FileViewer?
      @body.as?(Kodkod::FileViewer)
    end

    def title : String
      @body.name
    end

    def path : String?
      @body.path
    end

    def dirty? : Bool
      (b = buffer?) ? b.dirty? : false
    end
  end

  @docs = [] of Doc
  @next_doc_id = 1
  @next_untitled = 1
  # The tab selection signal — focus follows it (see notepad).
  reactive selected = 0
  @folder : String? = nil
  @status = "Ready."
  # The dirty docs awaiting the confirm-close modal (a batch close
  # from the tab context menu walks them one by one — see close_batch).
  @close_queue = [] of Doc
  @hotkeys_ready = false
  @focused_tab_version : UInt64 = UInt64::MAX
  @pending_close : Doc? = nil
  @quitting = false
  @show_fps = false
  # The About modal: `@about_open` gates the routed modal page (see
  # Kodkod::About); @about keeps the parsed icon across openings.
  @about_open = false
  @about : Kodkod::About
  # Whether the caption icon raster is the dark-chrome (light-art)
  # tint — nil before the first frame installs one.
  @caption_dark : Bool? = nil
  @search_open = false
  @search = ""
  @settings : Settings = Egui::SystemPorts::AppConfig.load(
    "kodkod", Settings.new)
  @i18n : Kodkod::I18n = Kodkod::I18n.new
  @vim : Kodkod::VimMode = Kodkod::VimMode.new
  @quick_open : Kodkod::QuickOpen = Kodkod::QuickOpen.new

  def initialize(files : Array(String) = [] of String, dir : String? = nil,
                 theme : String? = nil)
    super()
    @settings.theme = theme if theme
    @i18n.locale = @settings.language
    @about = Kodkod::About.new(@i18n)
    @status = t("status.ready")
    @vim.enabled = @settings.vim

    # The ':' command layer: editor builtins live in the runner; the
    # app registers everything that touches tabs, files, or quitting
    # (see register_vim_commands).
    register_vim_commands

    # When the Ctrl+P panel closes, the active editor takes focus back
    # (the query field held it).
    @quick_open.on_close = ->{
      if (doc = @docs[selected]?) && (fid = doc.focus_id)
        Kodkod::CodeEditor.request_focus(ctx, fid)
      end
    }

    Egui::WindowFrame.caption(
      height: Egui::TitleBarTabs::CAPTION_H) do |ctx, area|
      unless ctx.router.current.page == "settings"
        Egui::TitleBarTabs.show(ctx, area, @docs.map(&.title), selected,
          dirty: @docs.map(&.dirty?),
          on_select: ->(t : Int32) { self.selected = t; nil },
          on_close: ->(t : Int32) { request_close(@docs[t]?) },
          on_new: ->{ new_doc },
          on_context_menu: ->(tab : Int32, menu : Egui::Ui) {
            tab_context_menu(tab, menu)
            nil
          })
      end
    end

    if dir && Dir.exists?(dir)
      @folder = File.expand_path(dir)
    end
    if files.empty?
      @docs << make_doc(Kodkod::EditorBuffer.new(
        "kodkod — code editor on egui-cr\n" \
        "\n" \
        "Ctrl+N new tab, Ctrl+O open file, Ctrl+Shift+O open folder,\n" \
        "Ctrl+Shift+E toggles the explorer panel.\n" \
        "VIM: i a o O insert, Esc normal, dd x yy p edit, :w :q :wq,\n" \
        ":tabnew :tabn :tabp :tabc :tabs — tabs from the ':' line.\n" \
        "Rope buffer: this editor opens 20 MB files without a hiccup.\n"))
    else
      files.each { |f| open_path(f) }
    end
    self.selected = @docs.size - 1 if @docs.size > 0
  end

  # App actions (menus and hotkeys reference these, never key strings).
  ACTION_NEW         = Egui::HotkeyAction.new("kodkod.new")
  ACTION_OPEN        = Egui::HotkeyAction.new("kodkod.open")
  ACTION_OPEN_FOLDER = Egui::HotkeyAction.new("kodkod.open_folder")
  ACTION_SAVE        = Egui::HotkeyAction.new("kodkod.save")
  ACTION_SAVE_AS     = Egui::HotkeyAction.new("kodkod.save_as")
  ACTION_CLOSE       = Egui::HotkeyAction.new("kodkod.close")
  ACTION_QUIT        = Egui::HotkeyAction.new("kodkod.quit")
  ACTION_NEXT_TAB    = Egui::HotkeyAction.new("kodkod.next_tab")
  ACTION_PREV_TAB    = Egui::HotkeyAction.new("kodkod.prev_tab")
  ACTION_SETTINGS    = Egui::HotkeyAction.new("kodkod.settings")
  ACTION_SEARCH      = Egui::HotkeyAction.new("kodkod.search")
  ACTION_QUICK_OPEN  = Egui::HotkeyAction.new("kodkod.quick_open")
  ACTION_REFRESH     = Egui::HotkeyAction.new("kodkod.refresh")
  ACTION_TOGGLE_VIM  = Egui::HotkeyAction.new("kodkod.toggle_vim")
  ACTION_TOGGLE_EXPLORER = Egui::HotkeyAction.new("kodkod.toggle_explorer")

  DEFAULT_BINDINGS = {
    ACTION_NEW         => "Ctrl+N",
    ACTION_OPEN        => "Ctrl+O",
    ACTION_OPEN_FOLDER => "Ctrl+Shift+O",
    ACTION_SAVE        => "Ctrl+S",
    ACTION_SAVE_AS     => "Ctrl+Shift+S",
    ACTION_CLOSE       => "Ctrl+W",
    ACTION_QUIT        => "Ctrl+Q",
    ACTION_NEXT_TAB    => "Ctrl+Tab",
    ACTION_PREV_TAB    => "Ctrl+Shift+Tab",
    ACTION_SETTINGS    => "Ctrl+Comma",
    ACTION_SEARCH      => "Ctrl+F",
    ACTION_QUICK_OPEN  => "Ctrl+P",
    ACTION_REFRESH     => "F5",
    ACTION_TOGGLE_VIM  => "Ctrl+Alt+V",
    ACTION_TOGGLE_EXPLORER => "Ctrl+Shift+E",
  }

  # The chrome panels (explorer sidebar, status bar) run a notch
  # smaller than the 16 px app default — code stays at full size.
  # Whole values only (the Ctrl +/- zoom steps whole points too).
  PANEL_FONT_SIZE = 13.0

  # Shrink ctx.style.font_size for a panel's subtree. Panels render
  # synchronously inside their block, so save/restore scopes the size
  # to exactly that content (ensure keeps the theme intact on a raise).
  private def with_panel_font(ctx : Egui::Context, &)
    old = ctx.style.font_size
    ctx.style.font_size = PANEL_FONT_SIZE
    begin
      yield
    ensure
      ctx.style.font_size = old
    end
  end

  def update(ctx : Egui::Context) : Nil
    ctx.theme = @settings.theme == "Light" ? Egui::Theme.light : Egui::Theme.dark

    # The caption icon slot follows the theme: the monochrome art is
    # baked in two tints (app_icon.cr) — near-white on the dark
    # chrome, near-black on the light one. Swapped once per flip:
    # WindowFrame.icon= invalidates the cached texture.
    dark = ctx.theme.dark?
    if dark != @caption_dark
      @caption_dark = dark
      Egui::WindowFrame.icon = Kodkod.icon_rgba(light: dark)
    end

    unless @hotkeys_ready
      DEFAULT_BINDINGS.each { |action, combo| ctx.hotkeys.bind(combo, action) }
      @hotkeys_ready = true
    end

    # Deep-link: `--page root/about` opens the modal (the same way
    # root/settings deep-links; the router pops back on Close).
    @about_open ||= ctx.router.current.page_id == "root/about"

    ctx.routes do |r|
      r.page "root/root" do
        ctx.menu_bar do |bar|
          bar.menu_button(t("menu.file")) do |menu|
            menu.menu_item(t("menu.new"), ACTION_NEW)
            menu.menu_item(t("menu.open"), ACTION_OPEN)
            menu.menu_item(t("menu.open_folder"), ACTION_OPEN_FOLDER)
            menu.menu_item(t("menu.go_to_file"), ACTION_QUICK_OPEN)
            menu.menu_item(t("menu.save"), ACTION_SAVE)
            menu.menu_item(t("menu.save_as"), ACTION_SAVE_AS)
            menu.menu_item(t("menu.close_tab"), ACTION_CLOSE)
            menu.menu_item(t("menu.quit"), ACTION_QUIT)
          end
          bar.menu_button(t("menu.edit")) do |menu|
            menu.menu_item(t("menu.find"), ACTION_SEARCH)
          end
          bar.menu_button(t("menu.view")) do |menu|
            menu.menu_item("#{@settings.show_explorer ? "✓ " : ""}#{t("menu.explorer")}",
              ACTION_TOGGLE_EXPLORER)
            menu.menu_item(t("menu.next_tab"), ACTION_NEXT_TAB)
            menu.menu_item(t("menu.prev_tab"), ACTION_PREV_TAB)
            menu.menu_item(t("menu.refresh"), ACTION_REFRESH)
            menu.menu_item("#{@settings.show_hidden ? "✓ " : ""}#{t("menu.hidden")}") do
              @settings.show_hidden = !@settings.show_hidden
              save_settings
            end
          end
          bar.menu_button(t("menu.settings")) do |menu|
            menu.menu_item(t("menu.settings_open"), ACTION_SETTINGS)
            menu.menu_item("#{@vim.enabled? ? "✓ " : ""}#{t("menu.vim")}",
              ACTION_TOGGLE_VIM)
            menu.menu_item("#{@show_fps ? "✓ " : ""}#{t("menu.fps")}") do
              @show_fps = !@show_fps
            end
          end
          bar.menu_button(t("menu.help")) do |menu|
            menu.menu_item(t("menu.about")) do
              open_about(ctx)
            end
          end
        end

        # Explorer: the workspace folder's tree in a resizable panel.
        # Toggled by the show_explorer setting; without an open folder
        # it shows an "Open Folder…" shortcut instead of the tree.
        if @settings.show_explorer
          ctx.side_panel(:left, "explorer", width: 240.0) do |ui|
            with_panel_font(ui.ctx) do
              if (folder = @folder)
                ui.label(File.basename(folder))
                ui.separator
                # The tree owns its scroll area (keyboard navigation
                # scrolls the focused row into view). `active` is a
                # pure function of the tab bar (reactive — see
                # notepad): whichever way a file becomes current (tree
                # click, Ctrl+O, Ctrl+P, ':' commands, tab switch) the
                # explorer follows — expanding to it and scrolling it
                # into view.
                ui.file_tree("explorer", folder,
                  active: @docs[selected]?.try(&.path),
                  show_hidden: @settings.show_hidden,
                  chevrons: false) do |path|
                  open_path(path, existing: true) if File.file?(path)
                end
              else
                ui.label(t("explorer.no_folder"))
                if ui.button(t("explorer.open")).clicked?
                  open_folder
                end
              end
            end
          end
        end

        ctx.central_panel do |ui|
          if @docs.empty?
            ui.label(t("editor.empty"))
          else
            active = @docs[selected]
            rect = ui.allocate_at_least(
              Egui::Vec2.new(ui.available_width, ui.available_height))
            editor = ui.child_ui(rect,
              Egui::Id.from("kodkod/doc-ui/#{selected}"))
            if (viewer = active.viewer?)
              # Image tab: the FileViewer fills the whole pane.
              viewer.show(editor)
            else
              buffer = active.buffer?.not_nil!
              editor.code_editor(buffer, focus_id: active.focus_id,
                keyboard: @vim.widget_keyboard,
                escape_clears_focus: !@vim.enabled?,
                # VIM's cursor never blinks (any mode); the setting
                # governs the standard (non-VIM) editor.
                rows: 100, cursor_style: @vim.cursor_style,
                cursor_blinks: !@vim.enabled? && @settings.cursor_blinks,
                # VIM highlights the caret cell, not the whole line.
                cursor_line: !@vim.enabled?,
                # Off = render plain (no tokenization/measured token
                # runs) — the long-line/minified-file escape hatch.
                syntax_highlight: @settings.syntax_highlight,
                on_context_menu: ->(menu : Egui::Ui) {
                  # A distinct local (a captured `buffer` widens to
                  # the nilable re-binding further down this method).
                  buf = active.buffer?.not_nil!
                  editor_context_menu(ctx, buf,
                    active.focus_id.not_nil!, menu)
                })
            end

            # ACTIVE TAB = ACTIVE EDITOR, reactively (see notepad).
            if selected_signal.version != @focused_tab_version
              @focused_tab_version = selected_signal.version
              @vim.reset
              if (fid = active.focus_id)
                Kodkod::CodeEditor.request_focus(ctx, fid)
              end
            end

            # The VIM layer runs AFTER the widget: it reads this
            # frame's keys and writes caret cells the widget applies
            # next frame (its own request_repaints cover the cycle).
            # Image tabs have no caret — nothing to drive.
            if (buffer = active.buffer?) && (fid = active.focus_id)
              @vim.handle(ctx, buffer, fid)
            end
          end
        end

        ctx.bottom_panel("status") do |ui|
          with_panel_font(ui.ctx) do
            if @search_open
              ui.text_edit_singleline(@search, hint: t("status.find_hint"),
                focus_id: "kodkod-search") { |txt| @search = txt }
              if ui.button(t("status.next")).clicked?
                find_next
              end
              if ui.button(t("status.prev")).clicked?
                find_next(backward: true)
              end
              if ui.button("✕").clicked?
                @search_open = false
              end
            end
            if (active = @docs[selected]?)
              if (viewer = active.viewer?)
                ui.label("#{t("status.viewer")}   #{viewer.status_info}   #{viewer.path}")
              elsif (buffer = active.buffer?)
                line, col = Kodkod::CodeEditor.cursor(ctx, buffer, active.focus_id.not_nil!)
                mode = @vim.enabled? ? @vim.status_label : t("status.standard")
                lang = buffer.lang || "plain"
                path = buffer.path || buffer.name
                # A ':' line being typed takes over the ruler spot (vim's
                # command line sits over the Ln/Col area).
                pos = @vim.enabled? && @vim.mode.command? \
                  ? ":#{@vim.command}█" : t("status.ruler", line: line + 1, col: col + 1)
                ui.label("#{mode}   #{pos}   " \
                         "#{lang}   #{path}#{active.dirty? ? t("status.modified") : ""}")
              end
            end
            ui.label(@status)
            if @show_fps
              ctx.request_repaint
              ui.label("FPS: #{"%.1f" % ctx.fps}")
            end

            # The VIM command-line feedback (bottom-most, like vim): the
            # last command's result — errors red, warnings yellow. The
            # line being typed lives up in the status bar, over the ruler.
            if @vim.enabled?
              if (msg = @vim.commands.last_message)
                text = Egui::RichText.new(msg.text).code
                case msg.kind
                when .error? then text = text.color(Egui::Color32.rgb(0xf0, 0x5a, 0x5a))
                when .warn?  then text = text.color(Egui::Color32.rgb(0xe0, 0xb0, 0x40))
                end
                ui.rich(text)
              end
            end
          end
        end
      end

      r.page "root/settings", title: t("settings.title") do |ui|
        ui.heading(t("settings.title"))
        ui.label(t("settings.theme"))
        ui.combo_box("theme", @settings.theme, THEMES) do |name|
          @settings.theme = name
          save_settings
        end
        ui.label(t("settings.language"))
        current = Kodkod::I18n::LANGUAGES.fetch(@settings.language,
          @settings.language)
        ui.combo_box("language", current,
          Kodkod::I18n::LANGUAGES.values) do |name|
          if (code = Kodkod::I18n::LANGUAGES.key_for?(name))
            @settings.language = code
            @i18n.locale = code
            save_settings
          end
        end
        ui.separator
        if ui.selectable_label(@vim.enabled?, t("settings.vim")).clicked?
          toggle_vim
        end
        if ui.selectable_label(@settings.show_hidden, t("settings.hidden")).clicked?
          @settings.show_hidden = !@settings.show_hidden
          save_settings
        end
        if ui.selectable_label(@settings.show_explorer, t("settings.explorer")).clicked?
          @settings.show_explorer = !@settings.show_explorer
          save_settings
        end
        if ui.selectable_label(@settings.cursor_blinks, t("settings.blink")).clicked?
          @settings.cursor_blinks = !@settings.cursor_blinks
          save_settings
        end
        if ui.selectable_label(@settings.syntax_highlight, t("settings.syntax")).clicked?
          @settings.syntax_highlight = !@settings.syntax_highlight
          save_settings
        end
        ui.separator
        ui.label(t("settings.deeplink"))
      end

      if @pending_close
        pending_doc = @pending_close.not_nil!
        r.modal "root/confirm-close",
          title: @quitting ? t("confirm.quit_title") : t("confirm.title"),
          buttons: [t("confirm.save"), t("confirm.discard"), t("confirm.cancel")],
          on_button: ->(label : String) {
            @pending_close = nil
            ctx.router.back
            case label
            when t("confirm.save")
              save_and_close(pending_doc)
            when t("confirm.discard")
              do_close(pending_doc)
              continue_quit
              advance_close_queue(pending_doc)
            else
              @quitting = false
              @close_queue.clear
            end
          } do |ui|
          ui.label(t("confirm.body", title: pending_doc.title))
        end
      end

      if @about_open
        r.modal "root/about", title: t("about.title"), width: 420.0,
          buttons: [t("about.close")],
          on_button: ->(label : String) {
            @about_open = false
            ctx.router.back
          } do |ui|
          @about.show(ui)
        end
      end
    end

    # Files dropped onto the window open as tabs.
    ctx.input.dropped_files.each { |path| open_path(path) }

    # The Ctrl+P fuzzy file finder: rows are workspace-relative, the
    # pick joins them back onto the open folder. Closing it hands focus
    # back to the active editor (the query field cleared it).
    @quick_open.hint = t("quickopen.hint")
    @quick_open.show(ctx) do |rel|
      if (folder = @folder)
        open_path(File.join(folder, rel), existing: true)
      end
    end

    handle_actions(ctx)
  end

  private def save_settings : Nil
    Egui::SystemPorts::AppConfig.save("kodkod", @settings)
  end

  # Translate a UI string in the active locale (see Kodkod::I18n).
  private def t(key : String, **args) : String
    @i18n.t(key, **args)
  end

  private def handle_actions(ctx : Egui::Context) : Nil
    new_doc if ctx.consume_action(ACTION_NEW)
    open_doc if ctx.consume_action(ACTION_OPEN)
    open_folder if ctx.consume_action(ACTION_OPEN_FOLDER)
    save_doc if ctx.consume_action(ACTION_SAVE)
    save_doc_as if ctx.consume_action(ACTION_SAVE_AS)
    close_tab if ctx.consume_action(ACTION_CLOSE) && !@docs.empty?
    quit_flow if ctx.consume_action(ACTION_QUIT)
    next_tab if ctx.consume_action(ACTION_NEXT_TAB)
    previous_tab if ctx.consume_action(ACTION_PREV_TAB)
    if ctx.consume_action(ACTION_SEARCH)
      @search_open = true
    end
    quick_open if ctx.consume_action(ACTION_QUICK_OPEN)
    if ctx.consume_action(ACTION_REFRESH)
      Kodkod::FileTree.refresh
      @status = t("status.refreshed")
    end
    toggle_vim if ctx.consume_action(ACTION_TOGGLE_VIM)
    toggle_explorer if ctx.consume_action(ACTION_TOGGLE_EXPLORER)
    ctx.router.navigate("root/settings") if ctx.consume_action(ACTION_SETTINGS)
  end

  private def toggle_explorer : Nil
    @settings.show_explorer = !@settings.show_explorer
    save_settings
    @status = t("status.explorer",
      state: @settings.show_explorer ? t("explorer.shown") : t("explorer.hidden"))
  end

  # Ctrl+P: toggle the Sublime-style fuzzy file finder over the
  # workspace folder (no folder open — nothing to search).
  private def quick_open : Nil
    if @quick_open.open?(ctx)
      @quick_open.close(ctx)
      return
    end
    if (folder = @folder)
      @quick_open.open(ctx, folder, @settings.show_hidden)
    else
      @status = t("status.no_folder")
    end
  end

  private def toggle_vim : Nil
    @vim.enabled = !@vim.enabled?
    @settings.vim = @vim.enabled?
    @vim.reset unless @vim.enabled?
    save_settings
    @status = t("status.vim_state",
      state: @vim.enabled? ? t("vim.on") : t("vim.off"))
  end

  # --- documents -----------------------------------------------------

  private def make_doc(buffer : Kodkod::EditorBuffer) : Doc
    Doc.new(buffer, "doc-#{@next_doc_id += 1}")
  end

  private def lang_for(path : String) : String?
    LANG_BY_EXT[File.extname(path).downcase]? ||
      LANG_BY_NAME[File.basename(path).downcase]?
  end

  # The About modal (a routed page — see Kodkod::About).
  private def open_about(ctx : Egui::Context) : Nil
    @about_open = true
    ctx.router.navigate("root/about")
  end

  private def new_doc : Nil
    name = @next_untitled == 1 ? "untitled" : "untitled #{@next_untitled}"
    @next_untitled += 1
    @docs << make_doc(Kodkod::EditorBuffer.new("", path: nil, lang: nil))
    self.selected = @docs.size - 1
  end

  # Open `path` as a tab; `existing: true` just focuses it when the
  # file is already open (a click in the explorer). Returns whether a
  # tab now shows the path (the ':' commands report it).
  private def open_path(path : String, existing : Bool = false) : Bool
    expanded = File.expand_path(path)
    unless File.file?(expanded)
      STDERR.puts "kodkod: not a file: #{path}"
      return false
    end
    if (i = @docs.index { |d| d.path == expanded })
      self.selected = i
      return true
    end
    # Image files open in the FileViewer tab (PNG/SVG + the other
    # stb_image rasters); text goes on as before.
    # Image files open in the FileViewer tab; so does everything that
    # is not text — as a tab explaining the file cannot be shown
    # (silent skips lose the user's click).
    if Kodkod::FileViewer.supported?(expanded) ||
       !self.class.text_mime?(expanded)
      @docs << Doc.new(Kodkod::FileViewer.new(expanded))
      self.selected = @docs.size - 1
      kind = Kodkod::FileViewer.supported?(expanded) ? t("kind.image") : t("kind.no_preview")
      @status = t("status.opened_kind", path: expanded, kind: kind)
      return true
    end
    begin
      text = File.read(expanded)
      # A trailing newline is the file's business; the rope is as-is.
      @docs << make_doc(Kodkod::EditorBuffer.new(text, path: expanded,
        lang: lang_for(expanded)))
      self.selected = @docs.size - 1
      @status = t("status.opened_kib", path: expanded, kib: text.bytesize / 1024)
      true
    rescue e : IO::Error | File::Error
      STDERR.puts "kodkod: cannot read #{path}: #{e.message}"
      @status = t("status.cannot_read", path: path, err: e.message.to_s)
      false
    end
  end

  private def open_doc : Nil
    @status = t("status.opening")
    Egui::SystemPorts::OpenFileDialog.show(
      title: t("menu.open"), filters: [] of String) do |path|
      if path
        open_path(path)
      else
        @status = t("status.open_canceled")
      end
    end
  end

  private def open_folder : Nil
    Egui::SystemPorts::PickFolderDialog.show(title: t("menu.open_folder")) do |path|
      if path
        @folder = path
        @status = t("status.folder", path: path)
      end
    end
  end

  private def save_doc : Nil
    doc = @docs[selected]? || return
    if doc.viewer?
      @status = t("status.nothing_save")
      return
    end
    if (path = doc.buffer?.not_nil!.path)
      write_doc(doc, path)
    else
      save_doc_as
    end
  end

  private def save_doc_as : Nil
    doc = @docs[selected]? || return
    if doc.viewer?
      @status = t("status.nothing_save")
      return
    end
    default = (p = doc.path) ? File.basename(p) : "#{doc.title}.txt"
    Egui::SystemPorts::SaveFileDialog.show(
      title: t("menu.save_as"), default_name: default) do |dest|
      write_doc(doc, dest) if dest
    end
  end

  # Returns whether the file landed on disk (the ':' commands and the
  # close flow report it). Image tabs have nothing to write.
  private def write_doc(doc : Doc, path : String) : Bool
    buffer = doc.buffer? || return false
    begin
      File.write(path, buffer.text)
      buffer.path = path
      buffer.dirty = false
      # Re-highlight for the possibly-new language.
      buffer.lang = lang_for(path)
      @status = t("status.saved", path: path)
      true
    rescue e : IO::Error | File::Error
      @status = t("status.cannot_write", path: path, err: e.message.to_s)
      false
    end
  end

  private def close_tab : Nil
    request_close(@docs[selected]?)
  end

  # The right-click tab menu: close operations on the CLICKED tab
  # (not the selected one — the menu acts where it was opened) plus
  # Copy Path. Rows that cannot apply (no others / nothing to the
  # right) are simply absent.
  private def tab_context_menu(tab : Int32, menu : Egui::Ui) : Nil
    return unless (doc = @docs[tab]?)
    menu.menu_item(t("tab.close"), hotkey: "Ctrl+W") { request_close(doc) }
    if @docs.size > 1
      menu.menu_item(t("tab.close_others")) {
        close_batch(@docs.select { |d| !d.same?(doc) })
      }
    end
    if tab < @docs.size - 1
      menu.menu_item(t("tab.close_right")) { close_batch(@docs[(tab + 1)..]) }
    end
    if @docs.size > 1
      menu.menu_item(t("tab.close_all")) { close_batch(@docs.dup) }
    end
    if (path = doc.path)
      menu.separator
      menu.menu_item(t("tab.copy_path")) {
        Egui::SystemPorts::Clipboard.text = path
        @status = t("status.copied_path", path: path)
      }
    end
  end

  # The right-click editor menu: clipboard rows + Select All through
  # the class-level API, so they apply in EVERY VIM mode — in
  # normal/visual the widget keyboard is off and the menu (with the
  # Ctrl+C/X/V handling in VimMode) is the mouse-selection's copy
  # path. Rows that cannot apply (no selection / empty clipboard /
  # empty buffer) are grayed out.
  private def editor_context_menu(ctx : Egui::Context,
                                  buffer : Kodkod::EditorBuffer,
                                  fid : String, menu : Egui::Ui) : Nil
    menu.enabled(!Kodkod::CodeEditor.selection(ctx, fid).nil?) do |m|
      m.menu_item(t("edit.cut"), hotkey: "Ctrl+X") do
        if (s = Kodkod::CodeEditor.selection(ctx, fid))
          Egui::SystemPorts::Clipboard.text =
            buffer.rope.slice(s[0], s[1] - s[0])
          Kodkod::CodeEditor.delete_chars(ctx, buffer, fid, s[0], s[1] - s[0])
        end
      end
      m.menu_item(t("edit.copy"), icon: :copy, hotkey: "Ctrl+C") do
        Egui::SystemPorts::Clipboard.text =
          Kodkod::CodeEditor.selection_text(ctx, buffer, fid)
      end
    end
    menu.enabled(!Egui::SystemPorts::Clipboard.text.to_s.empty?) do |m|
      m.menu_item(t("edit.paste"), icon: :paste, hotkey: "Ctrl+V") do
        if (paste = Egui::SystemPorts::Clipboard.text)
          Kodkod::CodeEditor.insert_text(ctx, buffer, fid,
            paste.gsub(/\r\n|\r/, "\n"))
        end
      end
    end
    menu.enabled(buffer.rope.size > 0) do |m|
      m.menu_item(t("edit.select_all"), hotkey: "Ctrl+A") do
        Kodkod::CodeEditor.set_selection(ctx, fid, 0, buffer.rope.size)
      end
    end
  end

  # Batch close (Others / to the Right / All from the tab menu): the
  # clean tabs close at once; dirty ones walk the confirm-close modal
  # one at a time — @close_queue drives the chain exactly like the
  # quit flow does (advance_close_queue). Cancel stops the batch.
  private def close_batch(docs : Array(Doc)) : Nil
    docs = docs.select { |d| @docs.includes?(d) }
    # partition yields the block-TRUE elements first: dirty, then clean.
    dirty, clean = docs.partition(&.dirty?)
    clean.each { |d| do_close(d) }
    if dirty.empty?
      @status = t("status.closed_n", n: docs.size) unless docs.empty?
    else
      @close_queue = dirty
      request_close(dirty.first)
    end
  end

  # After the modal handled one queued doc: drop it, offer the modal
  # for the next dirty one (the quit chain has its own continue_quit).
  private def advance_close_queue(done : Doc) : Nil
    @close_queue.delete(done)
    return if @quitting
    if (next_doc = @close_queue.first?)
      @pending_close = next_doc
      ctx.router.navigate("root/confirm-close")
    end
  end

  private def request_close(doc : Doc?) : Nil
    return unless doc
    return if @pending_close
    if doc.dirty?
      @pending_close = doc
      ctx.router.navigate("root/confirm-close")
    else
      do_close(doc)
    end
  end

  private def do_close(doc : Doc) : Nil
    idx = @docs.index(doc) || return
    @docs.delete_at(idx)
    self.selected -= 1 if idx < selected
    self.selected = selected.clamp(0, {@docs.size - 1, 0}.max) unless @docs.empty?
    @status = t("status.closed", title: doc.title)
  end

  private def save_and_close(doc : Doc) : Nil
    if (path = doc.path)
      write_doc(doc, path)
      do_close(doc)
      continue_quit
      advance_close_queue(doc)
    else
      Egui::SystemPorts::SaveFileDialog.show(
        title: t("menu.save_as"), default_name: "#{doc.title}.txt") do |dest|
        if dest
          write_doc(doc, dest)
          do_close(doc)
          continue_quit
          advance_close_queue(doc)
        else
          @quitting = false
          @close_queue.clear
          @status = t("status.save_canceled")
        end
      end
    end
  end

  private def quit_flow : Nil
    dirty = @docs.select(&.dirty?)
    if dirty.empty?
      Egui::SystemPorts::Quit.quit!
    else
      @quitting = true
      @pending_close = dirty.first
      ctx.router.navigate("root/confirm-close")
    end
  end

  private def continue_quit : Nil
    return unless @quitting
    dirty = @docs.select(&.dirty?)
    if dirty.empty?
      Egui::SystemPorts::Quit.quit!
    else
      @pending_close = dirty.first
      ctx.router.navigate("root/confirm-close")
    end
  end

  private def next_tab : Nil
    return if @docs.size < 2
    self.selected = (selected + 1) % @docs.size
  end

  private def previous_tab : Nil
    return if @docs.size < 2
    self.selected = (selected - 1) % @docs.size
  end

  # --- VIM ':' commands (tabs / files / quit) ---------------------------
  #
  # Registered on the VimMode runner in #initialize; the editor-scope
  # builtins (:n, :noh) live in VimCommand::Runner itself. Handlers
  # wrap the private actions above and speak through Result messages,
  # which the command bar shows (errors red, warnings yellow).
  # Dangerous paths stay on the existing confirm modal (:q on a dirty
  # tab); an explicit '!' forces past it.

  private def register_vim_commands : Nil
    cmds = @vim.commands
    cmds.register("tabnew", ->vim_tabnew(Kodkod::VimCommand::Ctx))
    cmds.register("tabedit", ->vim_tabnew(Kodkod::VimCommand::Ctx))
    cmds.register("new", ->vim_tabnew(Kodkod::VimCommand::Ctx))
    cmds.register("tabnext", ->vim_tab_goto(Kodkod::VimCommand::Ctx))
    cmds.register("tabn", ->vim_tab_goto(Kodkod::VimCommand::Ctx))
    cmds.register("tabprevious", ->vim_tab_goto_back(Kodkod::VimCommand::Ctx))
    cmds.register("tabp", ->vim_tab_goto_back(Kodkod::VimCommand::Ctx))
    cmds.register("bnext", ->vim_tab_goto(Kodkod::VimCommand::Ctx))
    cmds.register("bprevious", ->vim_tab_goto_back(Kodkod::VimCommand::Ctx))
    cmds.register("tabclose", ->vim_tab_close(Kodkod::VimCommand::Ctx))
    cmds.register("tabc", ->vim_tab_close(Kodkod::VimCommand::Ctx))
    cmds.register("tabonly", ->vim_tab_only(Kodkod::VimCommand::Ctx))
    cmds.register("tabo", ->vim_tab_only(Kodkod::VimCommand::Ctx))
    cmds.register("tabs", ->vim_tabs(Kodkod::VimCommand::Ctx))
    cmds.register("edit", ->vim_edit(Kodkod::VimCommand::Ctx))
    cmds.register("write", ->vim_write(Kodkod::VimCommand::Ctx))
    cmds.register("w", ->vim_write(Kodkod::VimCommand::Ctx))
    cmds.register("wq", ->vim_wq(Kodkod::VimCommand::Ctx))
    cmds.register("x", ->vim_wq(Kodkod::VimCommand::Ctx))
    cmds.register("quit", ->vim_tab_close(Kodkod::VimCommand::Ctx))
    cmds.register("q", ->vim_tab_close(Kodkod::VimCommand::Ctx))
    cmds.register("qall", ->vim_qall(Kodkod::VimCommand::Ctx))
    cmds.register("wqall", ->vim_wqall(Kodkod::VimCommand::Ctx))
  end

  private def vim_tabnew(c : Kodkod::VimCommand::Ctx)
    if c.args.empty?
      new_doc
      Kodkod::VimCommand::Result.ok("New tab.")
    elsif open_path(c.args)
      Kodkod::VimCommand::Result.ok("Opened #{c.args}.")
    else
      Kodkod::VimCommand::Result.error("Cannot open #{c.args}.")
    end
  end

  private def vim_tab_goto(c : Kodkod::VimCommand::Ctx)
    return Kodkod::VimCommand::Result.error("No documents.") if @docs.empty?
    if c.args.empty?
      next_tab
    elsif c.args.matches?(/\A\d+\z/)
      self.selected = c.args.to_i.clamp(1, @docs.size) - 1
    else
      return Kodkod::VimCommand::Result.error(
        "E488: Trailing characters: #{c.args}")
    end
    Kodkod::VimCommand::Result.ok("Tab #{selected + 1} of #{@docs.size}.")
  end

  private def vim_tab_goto_back(c : Kodkod::VimCommand::Ctx)
    return Kodkod::VimCommand::Result.error("No documents.") if @docs.empty?
    if c.args.empty?
      previous_tab
    elsif c.args.matches?(/\A\d+\z/)
      self.selected = (selected - c.args.to_i) % @docs.size
    else
      return Kodkod::VimCommand::Result.error(
        "E488: Trailing characters: #{c.args}")
    end
    Kodkod::VimCommand::Result.ok("Tab #{selected + 1} of #{@docs.size}.")
  end

  # :tabclose / :quit — '!' skips the dirty confirm modal.
  private def vim_tab_close(c : Kodkod::VimCommand::Ctx)
    doc = @docs[selected]?
    return Kodkod::VimCommand::Result.error("No documents.") unless doc
    if c.force?
      do_close(doc)
      if doc.dirty?
        Kodkod::VimCommand::Result.warn(
          "Closed \"#{doc.title}\" — changes discarded.")
      else
        Kodkod::VimCommand::Result.ok("Closed: #{doc.title}")
      end
    else
      request_close(doc) # dirty → the confirm modal (the warning)
      Kodkod::VimCommand::Result.ok
    end
  end

  # :tabonly — close every clean tab but the active one; modified
  # ones are left open with a warning (one confirm modal at a time).
  private def vim_tab_only(c : Kodkod::VimCommand::Ctx)
    active = @docs[selected]?
    return Kodkod::VimCommand::Result.error("No documents.") unless active
    skipped = 0
    @docs.dup.each do |d|
      next if d.same?(active)
      d.dirty? ? (skipped += 1) : do_close(d)
    end
    if skipped > 0
      Kodkod::VimCommand::Result.warn(
        "#{skipped} modified tab(s) left open — close them with :q!")
    else
      Kodkod::VimCommand::Result.ok("Closed all other tabs.")
    end
  end

  private def vim_tabs(c : Kodkod::VimCommand::Ctx)
    Kodkod::VimCommand::Result.ok(@docs.map_with_index do |d, i|
      "#{i == selected ? ">" : " "} #{i + 1}#{d.dirty? ? " +" : ""} " \
      "#{d.path || d.title}"
    end.join('\n'))
  end

  # :e — reload the file behind the tab ('!' over a modified buffer),
  # or open a path as a new tab (tab semantics, not vim buffers).
  # Image tabs only take the open-a-path half.
  private def vim_edit(c : Kodkod::VimCommand::Ctx)
    doc = @docs[selected]?
    return Kodkod::VimCommand::Result.error("No documents.") unless doc
    if doc.viewer?
      if c.args.empty?
        return Kodkod::VimCommand::Result.error(
          "Cannot reload an image tab — :e PATH opens a file.")
      elsif open_path(c.args)
        return Kodkod::VimCommand::Result.ok("Opened #{c.args} in a new tab.")
      else
        return Kodkod::VimCommand::Result.error("Cannot open #{c.args}.")
      end
    end
    buffer = doc.buffer?.not_nil!
    if c.args.empty?
      path = buffer.path
      return Kodkod::VimCommand::Result.error("E32: No file name.") unless path
      if doc.dirty? && !c.force?
        return Kodkod::VimCommand::Result.error(
          "E37: No write since last change (add ! to force)")
      end
      begin
        text = File.read(path)
        Kodkod::CodeEditor.replace_range(ctx, buffer, doc.focus_id.not_nil!,
          0, buffer.rope.size, text)
        buffer.dirty = false
        Kodkod::VimCommand::Result.ok("Reloaded: #{path}")
      rescue e : IO::Error | File::Error
        Kodkod::VimCommand::Result.error("Cannot read #{path}: #{e.message}")
      end
    elsif open_path(c.args)
      Kodkod::VimCommand::Result.ok("Opened #{c.args} in a new tab.")
    else
      Kodkod::VimCommand::Result.error("Cannot open #{c.args}.")
    end
  end

  private def vim_write(c : Kodkod::VimCommand::Ctx)
    doc = @docs[selected]?
    return Kodkod::VimCommand::Result.error("No documents.") unless doc
    if doc.viewer?
      return Kodkod::VimCommand::Result.error("Nothing to write — image tab.")
    end
    buffer = doc.buffer?.not_nil!
    if c.args.empty?
      if (path = buffer.path)
        if write_doc(doc, path)
          Kodkod::VimCommand::Result.ok("Saved: #{path}")
        else
          Kodkod::VimCommand::Result.error("Cannot write #{path}.")
        end
      else
        save_doc_as # untitled → the dialog picks the name
        Kodkod::VimCommand::Result.ok("Save as… — choose where.")
      end
    elsif write_doc(doc, c.args)
      Kodkod::VimCommand::Result.ok("Saved: #{c.args}")
    else
      Kodkod::VimCommand::Result.error("Cannot write #{c.args}.")
    end
  end

  # :wq / :x — save, then close (clean now, so no confirm modal).
  private def vim_wq(c : Kodkod::VimCommand::Ctx)
    doc = @docs[selected]?
    return Kodkod::VimCommand::Result.error("No documents.") unless doc
    if doc.viewer?
      return Kodkod::VimCommand::Result.error("Nothing to write — image tab.")
    end
    if doc.buffer?.not_nil!.path.nil? && c.args.empty?
      save_doc_as
      return Kodkod::VimCommand::Result.warn(
        "Save as… opened — save, then :q.")
    end
    result = vim_write(c)
    return result if result.error?
    request_close(@docs[selected]?)
    Kodkod::VimCommand::Result.ok
  end

  # :qa — quit_flow walks dirty tabs through the confirm modal; '!'
  # discards everything.
  private def vim_qall(c : Kodkod::VimCommand::Ctx)
    if c.force?
      Egui::SystemPorts::Quit.quit!
      Kodkod::VimCommand::Result.warn("Quitting — changes discarded.")
    else
      quit_flow
      Kodkod::VimCommand::Result.ok
    end
  end

  private def vim_wqall(c : Kodkod::VimCommand::Ctx)
    @docs.dup.each do |d|
      next unless d.dirty?
      path = d.path
      return Kodkod::VimCommand::Result.error(
        "E32: No file name — save \"#{d.title}\" first.") unless path
      return Kodkod::VimCommand::Result.error("Cannot write #{path}.") \
        unless write_doc(d, path)
    end
    quit_flow
    Kodkod::VimCommand::Result.ok
  end


  # --- search ----------------------------------------------------------

  # Find the next (or previous) case-insensitive occurrence of the
  # query from the caret, wrapping around; line-wise scanning of the
  # rope (no whole-buffer flatten).
  private def find_next(backward : Bool = false) : Nil
    doc = @docs[selected]? || return
    buffer = doc.buffer? || return # image tabs have nothing to search
    return if @search.empty?
    rope = buffer.rope
    q = @search.downcase
    cur = Kodkod::CodeEditor.cursor_offset(ctx, doc.focus_id.not_nil!)
    line, col = rope.line_col_of(cur)
    lines = rope.line_count

    # lines after the caret (or before it, backwards), wrapping.
    order = if backward
      (line - 1).downto(0).to_a + (lines - 1).downto(line).to_a
    else
      (line + 1...lines).to_a + [line]
    end
    order.each do |li|
      text = rope.line_text(li).downcase
      idx = backward ? text.rindex(q, col - 1)
                     : text.index(q, li == line ? col + 1 : 0)
      next unless idx
      from = rope.line_start(li) + idx
      Kodkod::CodeEditor.set_selection(ctx, doc.focus_id.not_nil!, from, from + q.size)
      Kodkod::CodeEditor.set_cursor_offset(ctx, buffer, doc.focus_id.not_nil!, from + q.size)
      Kodkod::CodeEditor.scroll_to_line(ctx, doc.focus_id.not_nil!, li, center: true)
      @status = t("status.match", line: li + 1)
      return
    end
    @status = t("status.no_match", q: @search)
  end

  # --- mime sniffing (see notepad) --------------------------------------

  def self.mime_type(path : String) : String
    outp = IO::Memory.new
    Process.run("file", ["-b", "--mime-type", path],
      output: outp, error: :close)
    mime = outp.to_s.strip
    mime.empty? ? (MIME.from_filename?(path) || "") : mime
  rescue File::Error | IO::Error
    MIME.from_filename?(path) || ""
  end

  def self.text_mime?(path : String) : Bool
    mime = mime_type(path)
    mime.starts_with?("text/") || TEXT_MIME_EXTRAS.includes?(mime)
  end
end
