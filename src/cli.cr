# kodkod — the startup CLI. Egui::CLI pulls the framework's --page
# flag out of ARGV first; everything here parses what is left with
# the standard OptionParser. Positional arguments are files opened in
# tabs at startup.
#
# The parser never exits on its own: help/version/error land in the
# returned struct and the entrypoint (kodkod.cr) acts on them, so the
# parsing logic stays spec-able headlessly.

require "option_parser"

module Kodkod
  # Keep in sync with shard.yml.
  VERSION = "0.1.1"

  struct CLIOptions
    getter theme : String?
    getter dir : String
    getter files : Array(String)
    getter? help : Bool
    getter? version : Bool
    getter error : String?
    getter help_text : String

    def initialize(@theme : String?, @dir : String, @files : Array(String),
                   @help : Bool, @version : Bool, @error : String?,
                   @help_text : String)
    end

    THEMES = {"Dark", "Light"}

    def self.parse(argv : Array(String)) : self
      theme = nil
      dir = Dir.current
      help = false
      version = false
      error = nil
      parser = OptionParser.new do |p|
        p.banner = "Usage: kodkod [options] [file ...]"
        p.on("--theme NAME", "Start with theme NAME (Dark or Light)") do |v|
          unless THEMES.includes?(v)
            error = "unknown theme #{v} (Dark or Light)"
            next
          end
          theme = v
        end
        p.on("--dir PATH", "Open PATH as the workspace folder (default: cwd)") do |v|
          dir = v
        end
        # Consumed by Egui::CLI before this parser runs; listed so
        # --help documents it.
        p.on("--page ROUTE", "Deep-link router route, e.g. root/settings") { }
        p.on("-h", "--help", "Show this help and exit") { help = true }
        p.on("--version", "Show version and exit") { version = true }
        p.invalid_option { |opt| error = "unknown option #{opt}" }
      end
      parser.parse(argv)
      # parse deletes the options it handled; what survives is the
      # positional file list.
      new(theme, dir, argv.dup, help, version, error, parser.to_s)
    end
  end
end
