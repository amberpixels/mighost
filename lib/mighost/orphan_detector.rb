# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require_relative "snapshot"
require_relative "git_metadata"

module Mighost
  class OrphanDetector
    class OrphanedMigration
      attr_reader :version, :filename, :branch_name, :git_sha, :migrated_at, :source, :dismissed, :author_name, :author_email

      def initialize(version:, filename: nil, branch_name: nil, git_sha: nil, migrated_at: nil, source: nil, dismissed: false, author_name: nil, author_email: nil)
        @version = version
        @filename = filename
        @branch_name = branch_name
        @git_sha = git_sha
        @migrated_at = migrated_at
        @source = source
        @dismissed = dismissed
        @author_name = author_name
        @author_email = author_email
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
        file_versions = migration_file_versions
        dismissed_set = Snapshot.dismissed_versions.to_set
        snapshots_by_version = Snapshot.all_metadata.index_by(&:version)

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

          orphaned << OrphanedMigration.new(
            version: version,
            filename: snapshot&.filename,
            branch_name: snapshot&.branch_name,
            git_sha: snapshot&.git_sha,
            migrated_at: snapshot&.migrated_at,
            source: snapshot&.source,
            dismissed: is_dismissed,
            author_name: snapshot&.author_name,
            author_email: snapshot&.author_email
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

      # Load all migration file versions at once (single glob per path)
      def migration_file_versions
        versions = Set.new
        migration_paths.each do |path|
          Dir.glob(File.join(path, "*.rb")).each do |file|
            version = File.basename(file).split("_").first
            versions << version
          end
        end
        versions
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
