# frozen_string_literal: true

require_relative "snapshot"
require_relative "git_metadata"

module Mighost
  class OrphanDetector
    class OrphanedMigration
      attr_reader :version, :filename, :branch_name, :git_sha, :migrated_at, :source

      def initialize(version:, filename: nil, branch_name: nil, git_sha: nil, migrated_at: nil, source: nil)
        @version = version
        @filename = filename
        @branch_name = branch_name
        @git_sha = git_sha
        @migrated_at = migrated_at
        @source = source
      end

      def recoverable?
        source.present?
      end

      def recovery_source
        case source
        when "file" then :snapshot
        when "git" then :git
        end
      end
    end

    class << self
      attr_accessor :debug

      # Detect orphaned migrations using cached snapshot data only (instant)
      def detect
        orphaned = []
        versions = migrated_versions

        log "Found #{versions.count} migrated versions, checking for orphans..."

        versions.each_with_index do |version, idx|
          if migration_file_exists?(version)
            log "  [#{idx + 1}/#{versions.count}] #{version} - file exists, skipping"
            next
          end

          log "  [#{idx + 1}/#{versions.count}] #{version} - orphaned, checking snapshot..."
          snapshot = Snapshot.find_by_version(version)

          if snapshot
            log "    Found snapshot: #{snapshot.filename} (source: #{snapshot.source})"
          else
            log "    No snapshot found"
          end

          orphaned << OrphanedMigration.new(
            version: version,
            filename: snapshot&.filename,
            branch_name: snapshot&.branch_name,
            git_sha: snapshot&.git_sha,
            migrated_at: snapshot&.migrated_at,
            source: snapshot&.source
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
        ActiveRecord::Base.connection
                          .select_values("SELECT version FROM #{schema_migrations_table}")
                          .map(&:to_s)
      end

      def schema_migrations_table
        ActiveRecord::Base.connection.quote_table_name("schema_migrations")
      end

      def migration_file_exists?(version)
        migration_paths.any? do |path|
          Dir.glob(File.join(path, "#{version}_*.rb")).any?
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
