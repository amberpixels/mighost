# frozen_string_literal: true

require_relative "snapshot"
require_relative "git_recovery"

module Mighost
  class OrphanDetector
    class OrphanedMigration
      attr_reader :version, :filename, :branch_name, :git_sha, :migrated_at
      attr_reader :has_snapshot, :has_git_recovery, :git_recovery_data

      def initialize(version:, filename: nil, branch_name: nil, git_sha: nil, migrated_at: nil,
                     has_snapshot: false, git_recovery_data: nil)
        @version = version
        @filename = filename
        @branch_name = branch_name
        @git_sha = git_sha
        @migrated_at = migrated_at
        @has_snapshot = has_snapshot
        @git_recovery_data = git_recovery_data
        @has_git_recovery = git_recovery_data.present?
      end

      def recoverable?
        has_snapshot || has_git_recovery
      end

      def recovery_source
        if has_snapshot
          :snapshot
        elsif has_git_recovery
          :git
        end
      end
    end

    class << self
      attr_accessor :debug

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

          # If no snapshot, try to find in git history
          git_recovery_data = nil
          if snapshot.nil?
            log "    No snapshot, searching git history..."
            git_recovery_data = GitRecovery.find_migration(version)
            if git_recovery_data
              log "    Found in git: #{git_recovery_data[:branch]} @ #{git_recovery_data[:sha]}"
            else
              log "    Not found in git"
            end
          else
            log "    Found snapshot: #{snapshot.filename}"
          end

          orphaned << OrphanedMigration.new(
            version: version,
            filename: snapshot&.filename || git_recovery_data&.dig(:filename),
            branch_name: snapshot&.branch_name || git_recovery_data&.dig(:branch),
            git_sha: snapshot&.git_sha || git_recovery_data&.dig(:sha),
            migrated_at: snapshot&.migrated_at,
            has_snapshot: snapshot.present?,
            git_recovery_data: git_recovery_data
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
