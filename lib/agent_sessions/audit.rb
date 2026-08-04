# frozen_string_literal: true

module AgentSessions
  # Answers: are these plaintext transcripts inside anything that syncs?
  # Needs only Layer 1. Time Machine exclusion status is a planned addition.
  class Audit
    Finding = Data.define(:agent, :kind, :path, :bytes, :synced_to)

    SYNC_ROOTS = {
      dropbox: ["~/Dropbox"],
      icloud: ["~/Library/Mobile Documents"],
      cloud_storage: ["~/Library/CloudStorage"],
      onedrive: ["~/OneDrive"],
      google_drive: ["~/Google Drive"]
    }.freeze

    def initialize(stores, env: ENV)
      @stores = stores
      @env = env
    end

    def report
      @stores.flat_map do |store|
        store.layers.select(&:exists?).map do |location|
          Finding.new(
            agent: store.agent,
            kind: location.kind,
            path: location.path,
            bytes: bytes_under(location.path),
            synced_to: sync_services_for(location.path)
          )
        end
      end
    end

    private

    def bytes_under(path)
      return File.size(path) if File.file?(path)

      # FNM_DOTMATCH because a plain **/* skips dotfiles, and a byte total that
      # quietly omits them is worse than no total at all.
      Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sum do |entry|
        File.file?(entry) ? File.size(entry) : 0
      end
    end

    # Both sides are resolved through realpath before comparing. On macOS a
    # temp dir lives at /private/var/... behind a /var symlink, and ~/Dropbox
    # is frequently a symlink itself, so comparing raw paths silently misses.
    def sync_services_for(path)
      real = real_path(path) || path
      SYNC_ROOTS.select do |_service, roots|
        roots.any? do |root|
          expanded = real_path(expand(root))
          expanded && (real == expanded || real.start_with?("#{expanded}/"))
        end
      end.keys
    end

    def real_path(path)
      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      nil
    end

    # SYNC_ROOTS only ever holds the ~/... form, so this needs no ~user handling.
    def expand(path)
      File.expand_path(path.sub(%r{\A~(?=/|\z)}) { @env["HOME"] || Dir.home })
    end
  end
end
