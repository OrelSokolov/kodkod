# kodkod voice — dlopen helper: the voice subsystem's native libraries
# (libgigastt_ffi for STT, libsqlite3 for the recording queue) load at
# RUNTIME, never at link time, so builds without them stay valid and
# the Voice page degrades to "unavailable" instead of failing to boot.
#
# Search order (first hit wins): explicit ENV override, the directory
# holding the running binary ($ORIGIN — portable installs keep the lib
# next to kodkod), the repo's ext/ (dev builds), then the bare soname
# through the system loader (LD_LIBRARY_PATH / default paths).

lib LibDl
  fun dlopen = dlopen(filename : UInt8*, flag : Int32) : Void*
  fun dlsym = dlsym(handle : Void*, symbol : UInt8*) : Void*
  fun dlerror = dlerror : UInt8*
end

module Kodkod
  module Voice
    module Dl
      RTLD_NOW   = 2
      RTLD_LOCAL = 0

      # Candidate absolute paths for `soname` (nil entries skipped).
      def self.candidates(soname : String) : Array(String)
        [ENV["KODKOD_VOICE_#{soname.gsub(/[^A-Za-z0-9]/, "_").upcase}"]?,
         exe_dir.try { |d| File.join(d, soname) },
         dev_ext(soname)].compact
      end

      private def self.exe_dir : String?
        (exe = Process.executable_path) ? File.dirname(exe) : nil
      rescue
        nil
      end

      # The dev layout: kodkod repo checkout with ext/ beside src/.
      private def self.dev_ext(soname : String) : String?
        here = File.dirname(File.dirname(__DIR__)) # src/voice → repo
        path = File.join(here, "ext", soname)
        File.exists?(path) ? path : nil
      end

      # Open the library: explicit candidates first, then the bare
      # soname via the system search. nil when nothing loads.
      def self.open(sonames : Array(String)) : Void*?
        sonames.each do |soname|
          candidates(soname).each do |path|
            next unless path && File.exists?(path)
            if (h = raw_open(path))
              return h
            end
          end
          if (h = raw_open(soname))
            return h
          end
        end
        nil
      end

      private def self.raw_open(path : String) : Void*?
        LibDl.dlerror # clear the sticky error
        handle = LibDl.dlopen(path.to_unsafe, RTLD_NOW | RTLD_LOCAL)
        if handle.null?
          LibDl.dlerror
          nil
        else
          handle
        end
      end

      # Look up a symbol; nil when absent. The handle stays owned by
      # the caller (never dlclose'd — the libs live for the process
      # lifetime).
      def self.sym(handle : Void*, name : String) : Void*?
        ptr = LibDl.dlsym(handle, name.to_unsafe)
        ptr.null? ? nil : ptr
      end
    end
  end
end
