# kodkod — VimCommand: the ':' command layer behind the command bar.
#
# A registry of NAMED commands (`name` → handler proc) with vim-style
# resolution: exact name first, then a UNIQUE prefix ("tabn" is not
# registered but resolves via "tabnext"; an exact short alias like
# "tabn" beats prefixes). Zero matches is E492, several is E464 —
# the panel shows both in red like vim's E-messages.
#
# Layering: VimMode (the input layer) collects the ':' line and hands
# it to Runner#run; Runner knows nothing about the app. Editor-scope
# builtins (:{n} goto line, :noh) are registered here; app-scope
# commands (tabs, files, quit) are registered by KodkodApp. Handlers
# return a Result whose message (info/warn/error) stays in
# #last_message until the next command line — the command bar (see
# app.cr) renders it.

require "./code_editor"

module Kodkod
  module VimCommand
    enum Kind
      Info
      Warn
      Error
    end

    record Message, kind : Kind, text : String

    struct Result
      getter message : Message?

      def initialize(@message : Message? = nil)
      end

      def self.ok(text : String? = nil) : Result
        new(text ? Message.new(Kind::Info, text) : nil)
      end

      def self.warn(text : String) : Result
        new(Message.new(Kind::Warn, text))
      end

      def self.error(text : String) : Result
        new(Message.new(Kind::Error, text))
      end

      def error? : Bool
        @message.try(&.kind.error?) || false
      end
    end

    # What a handler sees: the active editor plus the parsed tail of
    # the command line ("q!" → force, "w foo.txt" → args "foo.txt").
    struct Ctx
      getter ctx : Egui::Context
      getter buffer : EditorBuffer
      getter focus_id : String
      getter args : String
      getter? force : Bool

      def initialize(@ctx : Egui::Context, @buffer : EditorBuffer,
                     @focus_id : String, @args : String = "",
                     @force : Bool = false)
      end
    end

    class Runner
      alias Handler = Ctx -> Result

      @commands = {} of String => Handler

      # The last command's feedback for the command bar; lives until
      # the next command runs (or a new ':' line starts — vim keeps
      # its messages the same way).
      property last_message : Message?

      def initialize
        register_builtins
      end

      def register(name : String, handler : Handler) : Nil
        @commands[name] = handler
      end

      def register(name : String, &handler : Handler) : Nil
        register(name, handler)
      end

      def clear_message : Nil
        @last_message = nil
      end

      # Parse and run one ':' line (no leading ':'). Sets
      # #last_message from the handler's Result (or a parse error).
      def run(ctx : Egui::Context, buffer : EditorBuffer, focus_id : String,
              line : String) : Nil
        stripped = line.strip
        if stripped.empty? # bare ':' + Enter — nothing, no message
          @last_message = nil
          return
        end

        # :123 — goto line; not a named command.
        if stripped.matches?(/\A\d+\z/)
          goto = {stripped.to_i - 1, 0}.max
          CodeEditor.goto_line(ctx, buffer, focus_id, goto, 0)
          @last_message = nil
          return
        end

        parts = stripped.split(/\s+/, 2)
        name = parts[0]
        args = (parts[1]? || "").strip
        force = false
        if name.ends_with?('!') # "q!" — the bang rides the name token
          force = true
          name = name.rchop('!')
        end

        case matches = @commands.keys.select(&.starts_with?(name)).sort
        when .empty?
          @last_message = Message.new(Kind::Error,
            "E492: Not an editor command: #{stripped}")
          return
        end
        unless @commands.has_key?(name)
          if matches.size > 1
            @last_message = Message.new(Kind::Error,
              "E464: Ambiguous use of \"#{name}\"")
            return
          end
          name = matches.first
        end

        result = @commands[name].not_nil!.call(
          Ctx.new(ctx, buffer, focus_id, args, force))
        @last_message = result.message
      end

      # Editor-scope commands — no app needed.
      private def register_builtins : Nil
        register("nohlsearch") do |c|
          cur = CodeEditor.cursor_offset(c.ctx, c.focus_id)
          CodeEditor.set_cursor_offset(c.ctx, c.buffer, c.focus_id, cur)
          Result.ok # silent like vim
        end
      end
    end
  end
end
