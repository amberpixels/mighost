# frozen_string_literal: true

require "mighost"
require "mighost/orphan_detector"
require "mighost/rollbacker"
require "mighost/snapshot"
require "mighost/ui"
require "mighost/git_metadata"
require "mighost/git_recovery"

namespace :mighost do
  desc "Show available commands"
  task :help do
    puts <<~HELP
      #{Mighost::UI.pastel.cyan("Mighost")} - Rollback Rails migrations even when the file is missing

      #{Mighost::UI.pastel.cyan("Commands:")}
        rails mighost:status              Show orphaned migrations (in DB but no file)
        rails mighost:rollback            Rollback orphaned migrations (interactive)
        rails mighost:rollback VERSION=x  Rollback specific migration
        rails mighost:scan                Capture migrations + search git for orphans
        rails mighost:list (ls)           List stored migration records
        rails mighost:cleanup             Remove stale records

      #{Mighost::UI.pastel.cyan("Options:")}
        FORCE=1    Skip confirmations (rollback, cleanup)
        VERSION=x  Target specific migration version (rollback)
        LIMIT=N    Limit output rows (list)
        DEBUG=1    Verbose output (status)

      #{Mighost::UI.pastel.cyan("Typical workflow:")}
        1. rails mighost:scan       # First time setup
        2. rails mighost:status     # Check for orphaned migrations
        3. rails mighost:rollback   # Rollback interactively

    HELP
  end


  desc "Show orphaned migrations (in DB but no file). DEBUG=1 for verbose output"
  task status: :environment do
    Mighost::OrphanDetector.debug = ENV["DEBUG"] == "1"
    orphans = Mighost::OrphanDetector.detect

    Mighost::UI.render_orphans_table(orphans)

    # Check for branch change if there are non-recoverable orphans
    non_recoverable = orphans.reject(&:recoverable?)
    if non_recoverable.any? && Mighost::OrphanDetector.branch_changed?
      puts ""
      Mighost::UI.hint "Branch changed since last scan. Run 'rails mighost:scan' to update recovery info."
    end
  end

  desc "Rollback orphaned migrations. VERSION=xxx for specific, FORCE=1 to skip confirmation"
  task rollback: :environment do
    version = ENV["VERSION"]
    force = ENV["FORCE"] == "1"

    # Single version mode
    if version
      begin
        Mighost::Rollbacker.rollback_version!(version)
        Mighost::UI.success "Successfully rolled back migration #{version}"
      rescue Mighost::SnapshotNotFound
        Mighost::UI.error "No record found for version #{version}"
      rescue Mighost::RollbackFailed => e
        Mighost::UI.error "Failed to rollback: #{e.message}"
      end
      next
    end

    # All orphans mode
    orphans = Mighost::OrphanDetector.detect.select(&:recoverable?)

    if orphans.empty?
      Mighost::UI.info "No recoverable orphaned migrations found."
      next
    end

    Mighost::UI.render_recoverable_list(orphans)

    results = { rolled_back: [], failed: [], skipped: [] }
    rollback_all = force

    orphans.each do |orphan|
      unless rollback_all
        response = Mighost::UI.confirm_each?(orphan)
        case response
        when :quit
          Mighost::UI.warning "\nAborted."
          break
        when :no
          results[:skipped] << orphan.version
          next
        when :all
          rollback_all = true
        end
      end

      begin
        Mighost::Rollbacker.rollback_version!(orphan.version)
        results[:rolled_back] << orphan.version
        Mighost::UI.success "  Rolled back #{orphan.version}"
      rescue StandardError => e
        results[:failed] << { version: orphan.version, error: e.message }
        Mighost::UI.error "  Failed: #{e.message}"
      end
    end

    # Summary
    puts ""
    Mighost::UI.info "Done: #{results[:rolled_back].size} rolled back, #{results[:skipped].size} skipped, #{results[:failed].size} failed"
  end

  desc "Scan and capture existing migrations, search git for orphans"
  task scan: :environment do
    migration_paths = Rails.application.config.paths["db/migrate"].to_ary
    migrated_versions = ActiveRecord::Base.connection
                                          .select_values("SELECT version FROM schema_migrations")
                                          .map(&:to_s)

    captured = 0
    git_recovered = 0

    # Phase 1: Capture existing migration files
    migration_paths.each do |path|
      Dir.glob(File.join(path, "*.rb")).each do |file|
        basename = File.basename(file)
        version = basename.split("_").first

        next unless migrated_versions.include?(version)
        next if Mighost::Snapshot.find_by_version(version)

        Mighost::Capturer.new(version, file).capture
        Mighost::UI.info "Captured: #{basename}"
        captured += 1
      end
    end

    # Phase 2: Search git for orphaned migrations without recovery info
    Mighost::UI.info "\nSearching git history for orphaned migrations..."

    orphan_versions = migrated_versions.reject do |version|
      # Has file on disk?
      migration_paths.any? { |p| Dir.glob(File.join(p, "#{version}_*.rb")).any? }
    end

    orphan_versions.each do |version|
      # Already have a snapshot for this version?
      next if Mighost::Snapshot.find_by_version(version)

      # Search git history
      git_data = Mighost::GitRecovery.find_migration(version)
      next unless git_data

      Mighost::Snapshot.store(
        version: version,
        content: git_data[:content],
        filename: git_data[:filename],
        branch_name: git_data[:branch],
        git_sha: git_data[:sha],
        source: "git"
      )
      Mighost::UI.info "Git recovered: #{git_data[:filename]} (from #{git_data[:branch]})"
      git_recovered += 1
    end

    # Phase 3: Store scan metadata
    current_branch = Mighost::GitMetadata.current_branch
    current_sha = Mighost::GitMetadata.current_sha
    Mighost::Snapshot.store_scan_metadata(branch: current_branch, sha: current_sha)

    # Summary
    puts ""
    Mighost::UI.success "Scan complete:"
    Mighost::UI.info "  - Captured #{captured} migration(s) from files"
    Mighost::UI.info "  - Recovered #{git_recovered} orphan(s) from git history"
    Mighost::UI.info "  - Scan context: #{current_branch} @ #{current_sha}"
  end

  desc "List stored migration records (LIMIT=N to limit)"
  task list: :environment do
    records = Mighost::Snapshot.all_snapshots

    if records.empty?
      Mighost::UI.info "No migration records stored."
      next
    end

    limit = ENV["LIMIT"]&.to_i
    total_count = records.count
    display_records = limit&.positive? ? records.first(limit) : records

    Mighost::UI.render_records_table(display_records, limit: limit, total_count: total_count)
  end

  task ls: :list

  desc "Clean up stale records for migrations no longer in schema_migrations"
  task cleanup: :environment do
    Mighost::Snapshot.ensure_table_exists!
    migrated_versions = ActiveRecord::Base.connection
                                          .select_values("SELECT version FROM schema_migrations")
                                          .map(&:to_s)

    all_record_versions = Mighost::Snapshot.all_versions
    stale_versions = all_record_versions - migrated_versions

    if stale_versions.empty?
      Mighost::UI.info "No stale records to clean up."
      next
    end

    Mighost::UI.warning "Found #{stale_versions.count} stale record(s):"
    stale_versions.each { |v| puts "  #{v}" }

    unless ENV["FORCE"] == "1"
      unless Mighost::UI.confirm?("Delete these records?")
        Mighost::UI.warning "Aborted."
        next
      end
    end

    stale_versions.each { |v| Mighost::Snapshot.delete_by_version(v) }
    Mighost::UI.success "Cleaned up #{stale_versions.count} record(s)."
  end
end
