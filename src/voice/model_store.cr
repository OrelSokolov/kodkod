# kodkod voice — the GigaAM model bundle: which files make a usable
# engine dir, downloading them (a curl subprocess — free redirects,
# no scheduler involvement), and integrity checking.
#
# The bundle is gigastt's pre-quantized `rnnt` set (INT8 encoder +
# decoder + joiner + vocab, ~310 MiB) pinned to the GitHub release
# models-v3-2026-10-09; checksums mirror
# gigastt-core/src/model/variant.rs (PREQUANT_RELEASE_BASE,
# encoder_int8_checksum, RNNT_CHECKSUMS).

require "digest/sha256"
require "file_utils"

module Kodkod
  module Voice
    class ModelStore
      class Error < Exception
      end

      RELEASE_BASE = "https://github.com/ekhodzitsky/gigastt/releases/download/models-v3-2026-10-09"

      # name → pinned SHA-256 ("" = skip the integrity check).
      FILES = {
        "v3_rnnt_encoder_int8.onnx" => "1d5a6f580b692e38ba35ed98d0f54648808f27b0a147dc11bd8978c15dc1a18f",
        "v3_rnnt_decoder.onnx"      => "443c3b7bd42b453611618135d6b1e7d9467e5dd97c8a68501da4aa355750c0da",
        "v3_rnnt_joint.onnx"        => "fd1d02f45c2ad3d6b67cc149811ad794ab4b020ed49a0a9e2790a8619d1cddd8",
        "v3_vocab.txt"              => "a9143c30844d3c0bee3e9e927e4084774eb1b9eeaafc473b2c4521e4911a7c07",
      }

      getter dir : String

      def initialize(@dir : String)
        Dir.mkdir_p(@dir)
      end

      def path_for(name : String) : String
        File.join(@dir, name)
      end

      # Every file present (size checked, not digest — hashing 300 MB
      # runs only after a download, see #verify).
      def complete? : Bool
        FILES.all? do |name, _|
          path = path_for(name)
          File.exists?(path) && File.size(path) > 0
        end
      end

      def missing : Array(String)
        FILES.keys.reject { |n| (p = path_for(n)) && File.exists?(p) && File.size(p) > 0 }
      end

      def verify(name : String) : Bool
        expected = FILES[name]? || ""
        return true if expected.empty?
        path = path_for(name)
        return false unless File.exists?(path) && File.size(path) > 0
        sha256_file(path) == expected
      rescue File::Error
        false
      end

      # Streaming digest — verify runs on a fiber, never the UI frame.
      private def sha256_file(path : String) : String
        digest = Digest::SHA256.new
        File.open(path) do |f|
          buf = Bytes.new(1 << 20)
          while (n = f.read(buf)) > 0
            digest.update(buf[0, n])
          end
        end
        digest.hexfinal
      end

      # --- download -----------------------------------------------------
      #
      # One curl process per file, writing `<name>.part`; the poll API
      # (expected_bytes / done_bytes) lets the UI draw a progress bar.
      # Cancel kills the process and removes the .part.

      getter downloading_file : String? = nil
      getter done_bytes : Int64 = 0_i64
      getter expected_bytes : Int64 = 0_i64
      getter download_error : String? = nil
      getter? downloading : Bool = false

      @proc : Process? = nil

      def downloading? : Bool
        @downloading
      end

      def start_download : Nil
        return if downloading?
        # Pick the target off the UI thread: digest checks over a
        # present bundle are hundreds of MB of hashing.
        spawn(name: "kodkod-voice-verify") do
          target = FILES.keys.find { |name| !verify(name) }
          begin_download(target) if target
        end
      end

      private def begin_download(target : String) : Nil
        return if downloading?
        @downloading = true
        @download_error = nil
        @downloading_file = target
        @done_bytes = 0_i64
        @expected_bytes = remote_size(target) || 0_i64
        @proc = Process.new(
          "curl", ["-fsSL", "--retry", "3", "-o", part_path(target),
                   "#{RELEASE_BASE}/#{target}"],
          error: Process::Redirect::Pipe)
        spawn(name: "kodkod-voice-dl") { babysit(target) }
      end

      def cancel_download : Nil
        return unless downloading?
        if (proc = @proc)
          begin
            proc.terminate
          rescue e : Exception
          end
        end
        @downloading = false
      end

      # Poll the .part size; called from the UI frame.
      def poll_download : Nil
        return unless downloading?
        if (name = @downloading_file) && File.exists?(part_path(name))
          @done_bytes = File.size(part_path(name)).to_i64
        end
      end

      def progress : Float64
        return 0.0 unless downloading? && @expected_bytes > 0
        (@done_bytes.to_f / @expected_bytes).clamp(0.0, 1.0)
      end

      private def part_path(name : String) : String
        File.join(@dir, "#{name}.part")
      end

      # Content-Length after redirects (best effort; 0 = unknown).
      private def remote_size(name : String) : Int64?
        outp = Process.run("curl", ["-fsIL", "#{RELEASE_BASE}/#{name}"],
          output: :pipe) { |p| p.output.gets_to_end }
        outp.scan(/^content-length:\s*(\d+)/im).last?.try(&.[1].to_i64)
      rescue
        nil
      end

      # Wait for curl, verify the digest, swap the .part in — and chain
      # the next missing bundle file. Runs on a fiber; only touches
      # @-state and the filesystem (the .part poll above reads one
      # File.size — safe next to these writes).
      private def babysit(name : String) : Nil
        proc = @proc.not_nil!
        status = proc.wait
        @proc = nil
        @downloading = false
        if status.success? && File.exists?(part_path(name))
          if verify_part(name)
            File.rename(part_path(name), path_for(name))
          else
            File.delete?(part_path(name))
            @download_error = "контрольная сумма #{name} не совпала"
          end
        else
          err = proc.error?.try(&.gets_to_end.to_s.strip)
          File.delete?(part_path(name))
          code = status.normal_exit? ? "код #{status.exit_code}" : "процесс убит"
          @download_error = "curl (#{code})#{err && !err.empty? ? ": #{err[0, 200]}" : ""}"
        end
        # The bundle has four files — fetch the rest without another click.
        next_target = FILES.keys.find { |n| !File.exists?(path_for(n)) }
        begin_download(next_target) if next_target && @download_error.nil?
      rescue e : Exception
        @downloading = false
        @download_error = e.message.to_s
      end

      private def verify_part(name : String) : Bool
        expected = FILES[name]? || ""
        return true if expected.empty?
        sha256_file(part_path(name)) == expected
      end
    end
  end
end
