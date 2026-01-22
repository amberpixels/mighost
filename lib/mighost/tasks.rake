# frozen_string_literal: true

require "mighost"
require "mighost/orphan_detector"
require "mighost/rollbacker"
require "mighost/snapshot"
require "mighost/ui"

namespace :mighost do
  desc "Show orphaned migrations (in DB but no file). DEBUG=1 for verbose output"
  task status: :environment do
    Mighost::OrphanDetector.debug = ENV["DEBUG"] == "1"
    orphans = Mighost::OrphanDetector.detect

    Mighost::UI.render_orphans_table(orphans)
  end

  desc "Rollback orphaned migrations using stored snapshots"
  task rollback: :environment do
    orphans = Mighost::OrphanDetector.detect.select(&:recoverable?)

    if orphans.empty?
      Mighost::UI.info "No recoverable orphaned migrations found."
      next
    end

    Mighost::UI.render_recoverable_list(orphans)

    unless ENV["FORCE"] == "1"
      unless Mighost::UI.confirm?("Rollback all #{orphans.count} migration(s)?")
        Mighost::UI.warning "Aborted."
        next
      end
    end

    Mighost::UI.info "\nRolling back..."
    results = Mighost::Rollbacker.rollback_all_orphaned!

    Mighost::UI.render_rollback_results(results)
  end

  desc "Rollback a specific orphaned migration by version"
  task rollback_version: :environment do
    version = ENV["VERSION"]

    unless version
      Mighost::UI.warning "Usage: rails mighost:rollback_version VERSION=20240115123456"
      next
    end

    begin
      Mighost::Rollbacker.rollback_version!(version)
      Mighost::UI.success "Successfully rolled back migration #{version}"
    rescue Mighost::SnapshotNotFound
      Mighost::UI.error "No snapshot found for version #{version}"
    rescue Mighost::RollbackFailed => e
      Mighost::UI.error "Failed to rollback: #{e.message}"
    end
  end

  desc "Capture existing migrations (for initial setup)"
  task capture_existing: :environment do
    migration_paths = Rails.application.config.paths["db/migrate"].to_ary
    migrated_versions = ActiveRecord::Base.connection
                                          .select_values("SELECT version FROM schema_migrations")
                                          .map(&:to_s)

    captured = 0

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

    Mighost::UI.success "\nCaptured #{captured} migration(s)."
  end

  desc "Show stored snapshots (LIMIT=N to limit, default: paged)"
  task snapshots: :environment do
    snapshots = Mighost::Snapshot.all_snapshots

    if snapshots.empty?
      Mighost::UI.info "No snapshots stored."
      next
    end

    limit = ENV["LIMIT"]&.to_i
    total_count = snapshots.count
    display_snapshots = limit&.positive? ? snapshots.first(limit) : snapshots

    Mighost::UI.render_snapshots_table(display_snapshots, limit: limit, total_count: total_count)
  end

  desc "Clean up snapshots for migrations no longer in schema_migrations"
  task cleanup: :environment do
    Mighost::Snapshot.ensure_table_exists!
    migrated_versions = ActiveRecord::Base.connection
                                          .select_values("SELECT version FROM schema_migrations")
                                          .map(&:to_s)

    all_snapshot_versions = Mighost::Snapshot.all_versions
    stale_versions = all_snapshot_versions - migrated_versions

    if stale_versions.empty?
      Mighost::UI.info "No stale snapshots to clean up."
      next
    end

    Mighost::UI.warning "Found #{stale_versions.count} stale snapshot(s):"
    stale_versions.each { |v| puts "  #{v}" }

    unless ENV["FORCE"] == "1"
      unless Mighost::UI.confirm?("Delete these snapshots?")
        Mighost::UI.warning "Aborted."
        next
      end
    end

    stale_versions.each { |v| Mighost::Snapshot.delete_by_version(v) }
    Mighost::UI.success "Cleaned up #{stale_versions.count} snapshot(s)."
  end
end
