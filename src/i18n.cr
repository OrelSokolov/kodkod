# kodkod i18n: UI-string translation for the app chrome (menus, the
# settings page, the explorer panel, the status bar, the tab context
# menu, the confirm-close modal). A keyed dictionary per locale with
# `%{name}` interpolation; a missing key in the active locale falls
# back to English, a missing English key returns the key itself (the
# string stays visible instead of blowing up).
#
# The locale is a Settings field (`language`, persisted like the
# theme); LANGUAGES maps the stored code to the name the settings
# combo shows. VIM ':' command messages and the welcome buffer stay
# English on purpose — vim speaks vim.

module Kodkod
  class I18n
    # Stored locale code → display name (the settings combo options).
    LANGUAGES = {"en" => "English", "ru" => "Русский"}

    @locale : String

    def initialize(@locale = "en")
    end

    def locale : String
      @locale
    end

    # Unknown codes are ignored — the locale stays put (the setting
    # never carries one unless LANGUAGES grew a dictionary entry).
    def locale=(code : String)
      @locale = code if DICT.has_key?(code)
    end

    # Translate `key`, substituting `%{name}` placeholders from args.
    def t(key : String, **args) : String
      text = (DICT[@locale]?.try(&.[key]?) || DICT["en"][key]? || key)
      args.each { |name, value| text = text.gsub("%{#{name}}", value.to_s) }
      text
    end

    DICT = {
      "en" => {
        # menu bar
        "menu.file"            => "File",
        "menu.new"             => "New",
        "menu.open"            => "Open…",
        "menu.open_folder"     => "Open Folder…",
        "menu.go_to_file"      => "Go to File… (Ctrl+P)",
        "menu.save"            => "Save",
        "menu.save_as"         => "Save As…",
        "menu.close_tab"       => "Close Tab",
        "menu.quit"            => "Quit",
        "menu.edit"            => "Edit",
        "menu.find"            => "Find…",
        "menu.view"            => "View",
        "menu.explorer"        => "Explorer (Ctrl+Shift+E)",
        "menu.next_tab"        => "Next Tab",
        "menu.prev_tab"        => "Previous Tab",
        "menu.refresh"         => "Refresh Explorer",
        "menu.hidden"          => "Hidden files",
        "menu.settings"        => "Settings",
        "menu.settings_open"   => "Settings…",
        "menu.vim"             => "VIM mode (Ctrl+Alt+V)",
        "menu.fps"             => "Show FPS",
        "menu.help"            => "Help",
        "menu.about"           => "About kodkod",
        # about tab
        "about.title"          => "About",
        "about.tagline"        => "A code editor on egui-cr",
        "about.features"       => "Rope buffer · highlight.cr syntax · lazy file tree · VIM mode",
        "about.license"        => "MIT license",
        "about.close"          => "Close",
        # tab context menu
        "tab.close"            => "Close",
        "tab.close_others"     => "Close Others",
        "tab.close_right"      => "Close Tabs to the Right",
        "tab.close_all"        => "Close All Tabs",
        "tab.copy_path"        => "Copy Path",
        # editor context menu
        "edit.cut"             => "Cut",
        "edit.copy"            => "Copy",
        "edit.paste"           => "Paste",
        "edit.select_all"      => "Select All",
        # settings page
        "settings.title"       => "Settings",
        "settings.theme"       => "Theme:",
        "settings.language"    => "Language:",
        "settings.vim"         => "VIM mode",
        "settings.hidden"      => "Show hidden files",
        "settings.explorer"    => "Explorer panel",
        "settings.blink"       => "Blinking cursor",
        "settings.syntax"      => "Syntax highlighting",
        "settings.deeplink"    => "Deep-link with --page root/settings.",
        # explorer panel
        "explorer.no_folder"   => "No folder open.",
        "explorer.open"        => "Open Folder…",
        # central panel
        "editor.empty"         => "No documents open — File → New (Ctrl+N) or the \"+\" in the title bar.",
        # quick open
        "quickopen.hint"       => "Go to file…",
        # status bar
        "status.find_hint"     => "Find…",
        "status.next"          => "Next",
        "status.prev"          => "Prev",
        "status.viewer"        => "-- VIEWER --",
        "status.standard"      => "-- STANDARD --",
        "status.ruler"         => "Ln %{line}, Col %{col}",
        "status.modified"      => " — modified",
        # status messages
        "status.ready"         => "Ready.",
        "status.refreshed"     => "Explorer refreshed.",
        "status.explorer"      => "Explorer %{state}.",
        "explorer.shown"       => "shown",
        "explorer.hidden"      => "hidden",
        "status.no_folder"     => "No folder open — Ctrl+Shift+O opens one.",
        "status.vim_state"     => "VIM mode %{state}.",
        "vim.on"               => "on",
        "vim.off"              => "off",
        "status.opening"       => "Opening dialog…",
        "status.open_canceled" => "Open canceled.",
        "status.folder"        => "Folder: %{path}",
        "status.opened_kind"   => "Opened: %{path} (%{kind})",
        "kind.image"           => "image",
        "kind.no_preview"      => "no preview",
        "status.opened_kib"    => "Opened: %{path} (%{kib} KiB)",
        "status.cannot_read"   => "Cannot read %{path}: %{err}",
        "status.nothing_save"  => "Nothing to save — image tab.",
        "status.saved"         => "Saved: %{path}",
        "status.cannot_write"  => "Cannot write %{path}: %{err}",
        "status.closed"        => "Closed: %{title}",
        "status.closed_n"      => "Closed %{n} tab(s).",
        "status.copied_path"   => "Copied: %{path}",
        "status.match"         => "Match at line %{line}.",
        "status.no_match"      => "No matches for \"%{q}\".",
        "status.save_canceled" => "Save canceled — the tab stays open.",
        # confirm-close modal
        "confirm.title"        => "Save changes?",
        "confirm.quit_title"   => "Save changes before quitting?",
        "confirm.save"         => "Save",
        "confirm.discard"      => "Don't save",
        "confirm.cancel"       => "Cancel",
        "confirm.body"         => "\"%{title}\" has unsaved changes.",
        # disk-change reload modal
        "reload.title"         => "File changed on disk",
        "reload.body"          => "\"%{title}\" (%{path}) was changed on disk by another program.",
        "reload.ask"           => "Reload it from disk?",
        "reload.reload"        => "Reload",
        "reload.keep"          => "Keep the editor's version",
        "status.reloaded"      => "Reloaded: %{path}",
      } of String => String,
      "ru" => {
        # menu bar
        "menu.file"            => "Файл",
        "menu.new"             => "Создать",
        "menu.open"            => "Открыть…",
        "menu.open_folder"     => "Открыть папку…",
        "menu.go_to_file"      => "Перейти к файлу… (Ctrl+P)",
        "menu.save"            => "Сохранить",
        "menu.save_as"         => "Сохранить как…",
        "menu.close_tab"       => "Закрыть вкладку",
        "menu.quit"            => "Выход",
        "menu.edit"            => "Правка",
        "menu.find"            => "Найти…",
        "menu.view"            => "Вид",
        "menu.explorer"        => "Проводник (Ctrl+Shift+E)",
        "menu.next_tab"        => "Следующая вкладка",
        "menu.prev_tab"        => "Предыдущая вкладка",
        "menu.refresh"         => "Обновить проводник",
        "menu.hidden"          => "Скрытые файлы",
        "menu.settings"        => "Настройки",
        "menu.settings_open"   => "Настройки…",
        "menu.vim"             => "Режим VIM (Ctrl+Alt+V)",
        "menu.fps"             => "Показывать FPS",
        "menu.help"            => "Справка",
        "menu.about"           => "О программе",
        # about tab
        "about.title"          => "О программе",
        "about.tagline"        => "Редактор кода на egui-cr",
        "about.features"       => "Rope-буфер · подсветка highlight.cr · ленивое дерево файлов · режим VIM",
        "about.license"        => "Лицензия MIT",
        "about.close"          => "Закрыть",
        # tab context menu
        "tab.close"            => "Закрыть",
        "tab.close_others"     => "Закрыть остальные",
        "tab.close_right"      => "Закрыть вкладки справа",
        "tab.close_all"        => "Закрыть все вкладки",
        "tab.copy_path"        => "Копировать путь",
        # editor context menu
        "edit.cut"             => "Вырезать",
        "edit.copy"            => "Копировать",
        "edit.paste"           => "Вставить",
        "edit.select_all"      => "Выделить всё",
        # settings page
        "settings.title"       => "Настройки",
        "settings.theme"       => "Тема:",
        "settings.language"    => "Язык:",
        "settings.vim"         => "Режим VIM",
        "settings.hidden"      => "Показывать скрытые файлы",
        "settings.explorer"    => "Панель проводника",
        "settings.blink"       => "Мигающий курсор",
        "settings.syntax"      => "Подсветка синтаксиса",
        "settings.deeplink"    => "Прямая ссылка: --page root/settings.",
        # explorer panel
        "explorer.no_folder"   => "Папка не открыта.",
        "explorer.open"        => "Открыть папку…",
        # central panel
        "editor.empty"         => "Нет открытых документов — Файл → Создать (Ctrl+N) или «+» в заголовке окна.",
        # quick open
        "quickopen.hint"       => "Перейти к файлу…",
        # status bar
        "status.find_hint"     => "Найти…",
        "status.next"          => "Далее",
        "status.prev"          => "Назад",
        "status.viewer"        => "-- ПРОСМОТР --",
        "status.standard"      => "-- ОБЫЧНЫЙ --",
        "status.ruler"         => "Стр %{line}, Стлб %{col}",
        "status.modified"      => " — изменён",
        # status messages
        "status.ready"         => "Готово.",
        "status.refreshed"     => "Проводник обновлён.",
        "status.explorer"      => "Проводник %{state}.",
        "explorer.shown"       => "показан",
        "explorer.hidden"      => "скрыт",
        "status.no_folder"     => "Папка не открыта — Ctrl+Shift+O открывает её.",
        "status.vim_state"     => "Режим VIM %{state}.",
        "vim.on"               => "включён",
        "vim.off"              => "выключен",
        "status.opening"       => "Открываю диалог…",
        "status.open_canceled" => "Открытие отменено.",
        "status.folder"        => "Папка: %{path}",
        "status.opened_kind"   => "Открыто: %{path} (%{kind})",
        "kind.image"           => "изображение",
        "kind.no_preview"      => "без предпросмотра",
        "status.opened_kib"    => "Открыто: %{path} (%{kib} KiB)",
        "status.cannot_read"   => "Не удалось прочитать %{path}: %{err}",
        "status.nothing_save"  => "Сохранять нечего — вкладка с изображением.",
        "status.saved"         => "Сохранено: %{path}",
        "status.cannot_write"  => "Не удалось записать %{path}: %{err}",
        "status.closed"        => "Закрыто: %{title}",
        "status.closed_n"      => "Закрыто вкладок: %{n}.",
        "status.copied_path"   => "Скопировано: %{path}",
        "status.match"         => "Совпадение в строке %{line}.",
        "status.no_match"      => "Нет совпадений для «%{q}».",
        "status.save_canceled" => "Сохранение отменено — вкладка остаётся открытой.",
        # confirm-close modal
        "confirm.title"        => "Сохранить изменения?",
        "confirm.quit_title"   => "Сохранить изменения перед выходом?",
        "confirm.save"         => "Сохранить",
        "confirm.discard"      => "Не сохранять",
        "confirm.cancel"       => "Отмена",
        "confirm.body"         => "У «%{title}» есть несохранённые изменения.",
        # disk-change reload modal
        "reload.title"         => "Файл изменён на диске",
        "reload.body"          => "«%{title}» (%{path}) изменён на диске другой программой.",
        "reload.ask"           => "Перезагрузить его с диска?",
        "reload.reload"        => "Перезагрузить",
        "reload.keep"          => "Оставить как в редакторе",
        "status.reloaded"      => "Перезагружено: %{path}",
      } of String => String,
    } of String => Hash(String, String)
  end
end
