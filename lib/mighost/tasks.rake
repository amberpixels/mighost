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
      #{Mighost::UI.color.cyan("Mighost")} - Rollback Rails migrations even when the file is missing

      #{Mighost::UI.color.cyan("Commands:")}
        rails mighost:status              Show orphaned migrations (in DB but no file)
        rails mighost:rollback            Rollback orphaned migrations (interactive)
        rails mighost:scan                Capture migrations + search git for orphans
        rails mighost:list (ls)           List stored migration records
        rails mighost:dismiss             Dismiss orphans (interactive, or VERSION=x)
        rails mighost:undismiss           Restore dismissed migrations
        rails mighost:dismissed           List dismissed migrations
        rails mighost:cleanup             Remove stale records

      #{Mighost::UI.color.cyan("Options:")}
        VERSION=x        Target specific version (rollback, dismiss, undismiss)
        VERSION=a..b     Version range: a to b inclusive
        VERSION=..b      All versions up to b
        VERSION=a..      All versions from a onwards
        FORCE=1          Skip confirmations
        OLD=1            Dismiss only old unrecoverable migrations (dismiss)
        SHOW_DISMISSED=1 Include dismissed in status
        LIMIT=N          Limit output rows (list)
        DEBUG=1          Verbose output (status)

      #{Mighost::UI.color.cyan("Typical workflow:")}
        1. rails mighost:scan       # First time setup
        2. rails mighost:status     # Check for orphaned migrations
        3. rails mighost:rollback   # Rollback interactively
        4. rails mighost:dismiss    # Dismiss unrecoverable orphans

    HELP
  end


  desc "Show orphaned migrations (in DB but no file). DEBUG=1, SHOW_DISMISSED=1"
  task status: :environment do
    Mighost::OrphanDetector.debug = ENV["DEBUG"] == "1"
    show_dismissed = ENV["SHOW_DISMISSED"] == "1"

    orphans = Mighost::OrphanDetector.detect(include_dismissed: show_dismissed)

    Mighost::UI.render_orphans_table(orphans)

    # Show dismissed count hint if there are dismissed migrations
    unless show_dismissed
      dismissed_count = Mighost::Snapshot.dismissed_versions.count
      if dismissed_count.positive?
        puts ""
        Mighost::UI.hint "#{dismissed_count} dismissed migration(s) hidden. Use SHOW_DISMISSED=1 to show."
      end
    end

    # Check for branch change if there are non-recoverable orphans
    non_recoverable = orphans.reject(&:recoverable?)
    if non_recoverable.any? && Mighost::OrphanDetector.branch_changed?
      puts "" unless show_dismissed
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
    migrated_versions = Mighost::Base.connection
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
      # Check if we already have a snapshot with recovery info
      existing = Mighost::Snapshot.find_by_version(version)
      next if existing&.source.present?

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
    migrated_versions = Mighost::Base.connection
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

  desc "Dismiss orphaned migrations (hide from status). VERSION=x, VERSION=a..b (range), OLD=1"
  task dismiss: :environment do
    version_param = ENV["VERSION"]
    old_only = ENV["OLD"] == "1"

    # Get non-dismissed orphans
    orphans = Mighost::OrphanDetector.detect(include_dismissed: false)

    # Filter to old unrecoverable migrations if OLD=1
    if old_only
      orphans = orphans.select(&:suggested_for_dismiss?)
      if orphans.empty?
        Mighost::UI.info "No old unrecoverable migrations to dismiss."
        Mighost::UI.hint "Migrations must be older than 6 months and not recoverable."
        next
      end
    end

    if orphans.empty?
      Mighost::UI.info "No orphaned migrations to dismiss."
      next
    end

    orphan_versions = orphans.map(&:version).sort

    # If VERSION specified, filter by range; otherwise use all
    if version_param
      to_dismiss = parse_version_range(version_param, orphan_versions)
      if to_dismiss.empty?
        Mighost::UI.warning "No matching orphaned migrations found."
        next
      end
    else
      to_dismiss = orphan_versions
    end

    orphan_map = orphans.index_by(&:version)

    # Show preview list
    puts "\n#{Mighost::UI.color.cyan("Found #{to_dismiss.count} orphaned migration(s) to dismiss:")}\n"
    preview_count = 10
    to_dismiss.first(preview_count).each do |v|
      puts "  #{v}  (#{Mighost::UI.format_version(v)})"
    end
    if to_dismiss.count > preview_count
      remaining = to_dismiss.count - preview_count
      newest = to_dismiss.last
      puts "  ... and #{remaining} more up to #{Mighost::UI.format_version(newest)}"
    end
    puts ""

    results = { dismissed: [], skipped: [] }
    dismiss_all = ENV["FORCE"] == "1"

    to_dismiss.each do |version|
      orphan = orphan_map[version]
      name = orphan&.filename || "(unknown)"

      unless dismiss_all
        response = Mighost::UI.confirm_dismiss?(version, name)
        case response
        when :quit
          Mighost::UI.warning "\nAborted."
          break
        when :no
          results[:skipped] << version
          next
        when :all
          # Show all remaining and confirm
          remaining = to_dismiss[to_dismiss.index(version)..]
          puts "\n#{Mighost::UI.color.cyan("Dismissing all remaining:")}"
          remaining.each do |v|
            o = orphan_map[v]
            puts "  #{Mighost::UI.color.dim(v)} - #{o&.filename || '(unknown)'}"
          end

          if Mighost::UI.confirm?("Confirm dismiss all #{remaining.count}?")
            remaining.each do |v|
              Mighost::Snapshot.dismiss(v)
              results[:dismissed] << v
            end
            Mighost::UI.success "  Dismissed #{remaining.count} migration(s)."
          else
            Mighost::UI.warning "Aborted."
          end
          break
        end
      end

      Mighost::Snapshot.dismiss(version)
      results[:dismissed] << version
      Mighost::UI.success "  Dismissed #{version}"
    end

    # Summary
    puts ""
    Mighost::UI.info "Done: #{results[:dismissed].size} dismissed, #{results[:skipped].size} skipped"
  end

  desc "Undismiss migrations (restore visibility). VERSION=x or VERSION=a..b"
  task undismiss: :environment do
    version_param = ENV["VERSION"]

    unless version_param
      Mighost::UI.error "VERSION required. Use same format as dismiss."
      next
    end

    dismissed = Mighost::Snapshot.dismissed_versions.sort

    if dismissed.empty?
      Mighost::UI.info "No dismissed migrations."
      next
    end

    targets = parse_version_range(version_param, dismissed)

    if targets.empty?
      Mighost::UI.warning "No matching dismissed migrations found."
      next
    end

    targets.each do |version|
      Mighost::Snapshot.undismiss(version)
      Mighost::UI.success "Undismissed #{version}"
    end

    Mighost::UI.info "\nRestored #{targets.count} migration(s) to status output."
  end

  desc "List dismissed migrations"
  task dismissed: :environment do
    dismissed = Mighost::Snapshot.dismissed_versions.sort

    if dismissed.empty?
      Mighost::UI.info "No dismissed migrations."
      next
    end

    puts "\n#{Mighost::UI.color.cyan("Dismissed migrations")} (#{dismissed.count}):\n\n"

    dismissed.each do |version|
      snapshot = Mighost::Snapshot.find_by_version(version)
      name = snapshot&.filename.presence || "(unknown)"
      dismissed_at = snapshot&.dismissed_at
      date_str = dismissed_at ? " (dismissed #{dismissed_at[0, 10]})" : ""
      puts "  #{Mighost::UI.color.dim(version)} - #{name}#{date_str}"
    end

    puts "\n#{Mighost::UI.color.cyan("Tip:")} Use 'rails mighost:undismiss VERSION=x' to restore."
  end

  # Helper to parse version range parameter
  def parse_version_range(param, available_versions)
    return [] if available_versions.empty?

    case param
    when /^\.\.(.+)$/ # ..bbb (up to)
      upper = $1
      available_versions.select { |v| v <= upper }
    when /^(.+)\.\.$/ # aaa.. (from onwards)
      lower = $1
      available_versions.select { |v| v >= lower }
    when /^(.+)\.\.(.+)$/ # aaa..bbb (range)
      lower, upper = $1, $2
      available_versions.select { |v| v >= lower && v <= upper }
    else # single version
      available_versions.include?(param) ? [param] : []
    end
  end
end
