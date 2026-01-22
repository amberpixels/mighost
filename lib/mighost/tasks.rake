# frozen_string_literal: true

require "mighost"
require "mighost/orphan_detector"
require "mighost/rollbacker"
require "mighost/snapshot"

namespace :mighost do
  desc "Show orphaned migrations (in DB but no file). DEBUG=1 for verbose output"
  task status: :environment do
    Mighost::OrphanDetector.debug = ENV["DEBUG"] == "1"
    orphans = Mighost::OrphanDetector.detect

    if orphans.empty?
      puts "No orphaned migrations found."
      next
    end

    recoverable_count = orphans.count(&:recoverable?)
    puts "\nOrphaned Migrations (#{orphans.count} total, #{recoverable_count} recoverable):\n\n"
    puts format("%-18s %-15s %-12s %-14s %s", "Version", "Branch", "SHA", "Recovery", "Name")
    puts "-" * 90

    orphans.each do |orphan|
      # Parse version (YYYYMMDDHHmmss) into readable date
      version = if orphan.version =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/
                  "#{$1}-#{$2}-#{$3} #{$4}:#{$5}"
                else
                  orphan.version
                end

      # Extract migration name from filename (remove timestamp prefix and .rb suffix)
      name = orphan.filename&.sub(/^\d+_/, "")&.sub(/\.rb$/, "") || "(unknown)"

      recovery = case orphan.recovery_source
                 when :snapshot then "snapshot"
                 when :git then "git"
                 else "-"
                 end

      puts format(
        "%-18s %-15s %-12s %-14s %s",
        version,
        (orphan.branch_name || "-")[0, 15],
        orphan.git_sha || "-",
        recovery,
        name
      )
    end

    puts "\nRun 'rails mighost:rollback' to rollback recoverable migrations."
  end

  desc "Rollback orphaned migrations using stored snapshots"
  task rollback: :environment do
    orphans = Mighost::OrphanDetector.detect.select(&:recoverable?)

    if orphans.empty?
      puts "No recoverable orphaned migrations found."
      next
    end

    puts "\nRecoverable orphaned migrations:"
    orphans.each do |orphan|
      puts "  #{orphan.version} - #{orphan.filename || '(unknown)'}"
    end

    unless ENV["FORCE"] == "1"
      print "\nRollback all #{orphans.count} migration(s)? [y/N] "
      response = $stdin.gets.chomp.downcase
      unless response == "y"
        puts "Aborted."
        next
      end
    end

    puts "\nRolling back..."
    results = Mighost::Rollbacker.rollback_all_orphaned!

    if results[:rolled_back].any?
      puts "\nSuccessfully rolled back:"
      results[:rolled_back].each { |v| puts "  #{v}" }
    end

    if results[:failed].any?
      puts "\nFailed to rollback:"
      results[:failed].each { |f| puts "  #{f[:version]}: #{f[:error]}" }
    end
  end

  desc "Rollback a specific orphaned migration by version"
  task rollback_version: :environment do
    version = ENV["VERSION"]

    unless version
      puts "Usage: rails mighost:rollback_version VERSION=20240115123456"
      next
    end

    begin
      Mighost::Rollbacker.rollback_version!(version)
      puts "Successfully rolled back migration #{version}"
    rescue Mighost::SnapshotNotFound
      puts "No snapshot found for version #{version}"
    rescue Mighost::RollbackFailed => e
      puts "Failed to rollback: #{e.message}"
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
        puts "Captured: #{basename}"
        captured += 1
      end
    end

    puts "\nCaptured #{captured} migration(s)."
  end

  desc "Show stored snapshots (LIMIT=N to limit, default: paged)"
  task snapshots: :environment do
    snapshots = Mighost::Snapshot.all_snapshots

    if snapshots.empty?
      puts "No snapshots stored."
      next
    end

    limit = ENV["LIMIT"]&.to_i
    total_count = snapshots.count
    snapshots = snapshots.first(limit) if limit&.positive?

    output = []
    output << "\nStored Snapshots (#{snapshots.count}#{limit ? " of #{total_count}" : ""}):\n\n"
    output << format("%-18s %-12s %-12s %-16s %s", "Version", "Branch", "SHA", "Captured", "Name")
    output << "-" * 90

    snapshots.each do |snapshot|
      # Parse version (YYYYMMDDHHmmss) into readable date
      migrated = if snapshot.version =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/
                   "#{$1}-#{$2}-#{$3} #{$4}:#{$5}"
                 else
                   snapshot.version
                 end

      # Extract migration name from filename (remove timestamp prefix and .rb suffix)
      name = snapshot.filename&.sub(/^\d+_/, "")&.sub(/\.rb$/, "") || "(unknown)"

      captured_at = case snapshot.migrated_at
                    when String then snapshot.migrated_at[0, 10]
                    when Time then snapshot.migrated_at.strftime("%Y-%m-%d")
                    else "-"
                    end

      output << format(
        "%-18s %-12s %-12s %-16s %s",
        migrated,
        (snapshot.branch_name || "-")[0, 12],
        snapshot.git_sha || "-",
        captured_at,
        name
      )
    end

    # Use pager if output is large and stdout is a TTY
    if $stdout.tty? && output.size > 30 && !limit
      pager = ENV["PAGER"] || "less"
      IO.popen(pager, "w") { |io| io.puts output.join("\n") }
    else
      puts output.join("\n")
    end
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
      puts "No stale snapshots to clean up."
      next
    end

    puts "Found #{stale_versions.count} stale snapshot(s):"
    stale_versions.each { |v| puts "  #{v}" }

    unless ENV["FORCE"] == "1"
      print "\nDelete these snapshots? [y/N] "
      response = $stdin.gets.chomp.downcase
      unless response == "y"
        puts "Aborted."
        next
      end
    end

    stale_versions.each { |v| Mighost::Snapshot.delete_by_version(v) }
    puts "Cleaned up #{stale_versions.count} snapshot(s)."
  end
end
