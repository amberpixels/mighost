# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require_relative "orphan_detector"
require_relative "snapshot"
require_relative "rollbacker"
require_relative "capturer"
require_relative "git_recovery"
require_relative "worktree_recovery"
require_relative "git_metadata"
require_relative "formatting"

module Mighost
  # Public API for programmatic access.
  # This is the stable interface for external consumers (e.g. railbow).
  module API
    module_function

    # Returns [OrphanedMigration]
    def orphaned_migrations(include_dismissed: false)
      OrphanDetector.detect(include_dismissed: include_dismissed)
    end

    # Returns Snapshot or nil
    def find_snapshot(version)
      Snapshot.find_by_version(version)
    end

    # Returns Snapshot (with git/worktree fallback) or nil
    def find_or_recover_snapshot(version)
      Snapshot.find_or_recover(version)
    end

    # Returns [Snapshot]
    def all_snapshots(limit: nil)
      records = Snapshot.all_snapshots
      limit&.positive? ? records.first(limit) : records
    end

    # Executes rollback. Raises SnapshotNotFound or RollbackFailed on failure.
    def rollback_version!(version)
      Rollbacker.rollback_version!(version)
    end

    # Scan: capture files, search git, search worktrees.
    # Returns {captured:, git_recovered:, worktree_recovered:, branch:, sha:, details:[]}
    def scan!(rescan: false)
      migration_paths = if defined?(Rails) && Rails.application
        Rails.application.config.paths["db/migrate"].to_ary
      else
        ["db/migrate"]
      end

      migrated_versions = Mighost::Base.connection
        .select_values("SELECT version FROM schema_migrations")
        .map(&:to_s)

      captured = 0
      git_recovered = 0
      worktree_recovered = 0
      details = []

      # Phase 1: Capture existing migration files
      migration_paths.each do |path|
        Dir.glob(File.join(path, "*.rb")).each do |file|
          basename = File.basename(file)
          version = basename.split("_").first

          next unless migrated_versions.include?(version)
          next if !rescan && Snapshot.find_by_version(version)

          Capturer.new(version, file).capture
          details << {type: :captured, filename: basename}
          captured += 1
        end
      end

      # Phase 2: Search git for orphaned migrations
      orphan_versions = migrated_versions.reject do |version|
        migration_paths.any? { |p| Dir.glob(File.join(p, "#{version}_*.rb")).any? }
      end

      orphan_versions.each do |version|
        existing = Snapshot.find_by_version(version)
        next if !rescan && existing&.source.present?

        git_data = GitRecovery.find_migration(version)
        next unless git_data

        Snapshot.store(
          version: version,
          content: git_data[:content],
          filename: git_data[:filename],
          branch_name: git_data[:branch],
          git_sha: git_data[:sha],
          source: "git",
          author_name: git_data[:author_name],
          author_email: git_data[:author_email]
        )
        details << {type: :git_recovered, filename: git_data[:filename], branch: git_data[:branch]}
        git_recovered += 1
      end

      # Phase 3: Search worktrees for uncommitted migrations
      remaining_orphans = orphan_versions.reject do |version|
        existing = Snapshot.find_by_version(version)
        !rescan && existing&.source.present?
      end

      remaining_orphans.each do |version|
        wt_data = WorktreeRecovery.find_migration(version)
        next unless wt_data

        Snapshot.store(
          version: version,
          content: wt_data[:content],
          filename: wt_data[:filename],
          branch_name: wt_data[:branch],
          source: "worktree",
          author_name: wt_data[:author_name],
          author_email: wt_data[:author_email]
        )
        details << {type: :worktree_recovered, filename: wt_data[:filename], branch: wt_data[:branch]}
        worktree_recovered += 1
      end

      # Store scan metadata
      branch = GitMetadata.current_branch
      sha = GitMetadata.current_sha
      Snapshot.store_scan_metadata(branch: branch, sha: sha)

      {
        captured: captured,
        git_recovered: git_recovered,
        worktree_recovered: worktree_recovered,
        branch: branch,
        sha: sha,
        details: details
      }
    end

    def dismiss(version)
      Snapshot.dismiss(version)
    end

    def undismiss(version)
      Snapshot.undismiss(version)
    end

    def dismissed_count
      Snapshot.dismissed_versions.count
    end
  end
end
