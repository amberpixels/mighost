# frozen_string_literal: true

require_relative "snapshot"

module Mighost
  class OrphanDetector
    class OrphanedMigration
      attr_reader :version, :filename, :branch_name, :git_sha, :migrated_at, :has_snapshot

      def initialize(version:, filename: nil, branch_name: nil, git_sha: nil, migrated_at: nil, has_snapshot: false)
        @version = version
        @filename = filename
        @branch_name = branch_name
        @git_sha = git_sha
        @migrated_at = migrated_at
        @has_snapshot = has_snapshot
      end

      def recoverable?
        has_snapshot
      end
    end

    class << self
      def detect
        orphaned = []

        migrated_versions.each do |version|
          next if migration_file_exists?(version)

          snapshot = Snapshot.find_by_version(version)

          orphaned << OrphanedMigration.new(
            version: version,
            filename: snapshot&.filename,
            branch_name: snapshot&.branch_name,
            git_sha: snapshot&.git_sha,
            migrated_at: snapshot&.migrated_at,
            has_snapshot: snapshot.present?
          )
        end

        orphaned.sort_by(&:version).reverse
      end

      def orphaned_count
        detect.count
      end

      def recoverable_count
        detect.count(&:recoverable?)
      end

      private

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
