# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require_relative "snapshot"
require_relative "git_metadata"
require_relative "supersession"

module Mighost
  class OrphanDetector
    class OrphanedMigration
      attr_reader :version, :filename, :branch_name, :git_sha, :migrated_at, :source, :dismissed, :author_name, :author_email,
        :superseded_by, :deleted_in_sha, :deleted_at, :deleted_by

      def initialize(version:, filename: nil, branch_name: nil, git_sha: nil, migrated_at: nil, source: nil, dismissed: false,
        author_name: nil, author_email: nil, superseded_by: nil, deleted_in_sha: nil, deleted_at: nil, deleted_by: nil)
        @version = version
        @filename = filename
        @branch_name = branch_name
        @git_sha = git_sha
        @migrated_at = migrated_at
        @source = source
        @dismissed = dismissed
        @author_name = author_name
        @author_email = author_email
        @superseded_by = superseded_by
        @deleted_in_sha = deleted_in_sha
        @deleted_at = deleted_at
        @deleted_by = deleted_by
      end

      # Schema change lives on under a re-timestamped version — a stale row, not a lost migration
      def superseded?
        !superseded_by.nil?
      end

      def recoverable?
        source.present?
      end

      def recovery_source
        case source
        when "file" then :snapshot
        when "git" then :branch
        when "worktree" then :worktree
        end
      end

      # Parse version timestamp (YYYYMMDDHHmmss) -> Time
      def created_at
        return @created_at if defined?(@created_at)

        @created_at = begin
          if version =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/
            Time.new($1.to_i, $2.to_i, $3.to_i, $4.to_i, $5.to_i, $6.to_i)
          end
        rescue ArgumentError
          nil
        end
      end

      # Is migration older than threshold?
      def old?(threshold: Mighost.configuration.dismiss_old_threshold)
        return false unless created_at

        created_at < threshold.ago
      end

      # Should suggest dismissal? (unrecoverable AND old)
      def suggested_for_dismiss?
        !recoverable? && old?
      end

      # Is actionable? (recoverable OR not old enough to suggest dismissal)
      def actionable?
        !suggested_for_dismiss?
      end
    end

    class << self
      attr_accessor :debug

      # Detect orphaned migrations using cached snapshot data only (instant)
      # @param include_dismissed [Boolean] whether to include dismissed migrations (default: false)
      def detect(include_dismissed: false)
        # Load everything upfront for performance
        versions = migrated_versions
        disk_files = migration_file_basenames
        file_versions = disk_files.map { |basename| basename.split("_").first }.to_set
        dismissed_set = Snapshot.dismissed_versions.to_set
        snapshots_by_version = Snapshot.all_metadata.index_by(&:version)
        hide_superseded = Mighost.configuration.hide_superseded

        log "Found #{versions.count} migrated versions, #{file_versions.count} files on disk"

        orphaned = []
        versions.each do |version|
          # Skip if file exists on disk
          next if file_versions.include?(version)

          # Skip dismissed unless requested
          is_dismissed = dismissed_set.include?(version)
          next if is_dismissed && !include_dismissed

          snapshot = snapshots_by_version[version]
          log "  #{version} - orphaned#{", has snapshot (#{snapshot.source})" if snapshot}"

          superseded_by = if snapshot&.filename.present?
            Supersession.find_superseder(
              version,
              filename: snapshot.filename,
              applied_versions: versions,
              disk_files: disk_files
            )
          end
          next if superseded_by && hide_superseded

          orphaned << OrphanedMigration.new(
            version: version,
            filename: snapshot&.filename,
            branch_name: snapshot&.branch_name,
            git_sha: snapshot&.git_sha,
            migrated_at: snapshot&.migrated_at,
            source: snapshot&.source,
            dismissed: is_dismissed,
            author_name: snapshot&.author_name,
            author_email: snapshot&.author_email,
            superseded_by: superseded_by,
            deleted_in_sha: snapshot&.deleted_in_sha,
            deleted_at: snapshot&.deleted_at,
            deleted_by: snapshot&.deleted_by
          )
        end

        log "Done. Found #{orphaned.count} orphaned migrations."
        orphaned.sort_by(&:version).reverse
      end

      def orphaned_count
        detect.count
      end

      def recoverable_count
        detect.count(&:recoverable?)
      end

      # Get stored scan metadata
      def scan_metadata
        Snapshot.scan_metadata
      end

      # Check if current branch/sha differs from last scan
      def branch_changed?
        metadata = scan_metadata
        return false unless metadata

        current_branch = GitMetadata.current_branch
        current_sha = GitMetadata.current_sha

        metadata[:branch] != current_branch || metadata[:sha] != current_sha
      end

      private

      def log(msg)
        puts "[mighost] #{msg}" if debug
      end

      def migrated_versions
        Mighost::Base.connection
          .select_values("SELECT version FROM #{schema_migrations_table}")
          .map(&:to_s)
      end

      def schema_migrations_table
        Mighost::Base.connection.quote_table_name("schema_migrations")
      end

      # Load all migration file basenames at once (single glob per path)
      def migration_file_basenames
        migration_paths.flat_map do |path|
          Dir.glob(File.join(path, "*.rb")).map { |file| File.basename(file) }
        end
      end

      def migration_paths
        if defined?(Rails) && Rails.application
          Rails.application.config.paths["db/migrate"].to_ary
        else
          ["db/migrate"]
        end
      end
    end
  end
end
