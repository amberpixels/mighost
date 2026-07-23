# frozen_string_literal: true

module Mighost
  # Detects re-timestamped migrations: a ghost version whose name suffix is owned
  # by another applied version with a file on disk is superseded, not lost.
  module Supersession
    module_function

    # Returns the superseding version (string) for `version`, or nil.
    # A superseder must be a different version, present in schema_migrations,
    # and own an on-disk migration file with the same name suffix — an applied
    # version whose own file is missing is itself a ghost, not a superseder.
    #
    # applied_versions and disk_files (migration file basenames) are injectable
    # so batch callers like OrphanDetector can reuse data they already loaded.
    def find_superseder(version, filename:, applied_versions: nil, disk_files: nil)
      suffix = name_suffix(filename)
      return nil unless suffix

      applied = applied_versions || load_applied_versions
      files = disk_files || load_disk_files

      # Newest candidate wins if several versions share the suffix
      files.sort.reverse_each do |basename|
        candidate = basename.split("_").first
        next if candidate == version.to_s
        next unless applied.include?(candidate)

        return candidate if name_suffix(basename) == suffix
      end
      nil
    end

    # "20260702110000_add_utility_belt_to_batcaves.rb" -> "add_utility_belt_to_batcaves"
    def name_suffix(basename)
      return nil if basename.nil? || basename.empty?

      basename.sub(/\.rb\z/, "").split("_", 2)[1]
    end

    def load_applied_versions
      Mighost::Base.connection
        .select_values("SELECT version FROM schema_migrations")
        .map(&:to_s)
    end

    def load_disk_files
      paths = if defined?(Rails) && Rails.application
        Rails.application.config.paths["db/migrate"].to_ary
      else
        ["db/migrate"]
      end

      paths.flat_map { |path| Dir.glob(File.join(path, "*.rb")).map { |f| File.basename(f) } }
    end
  end
end
