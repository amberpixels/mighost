# frozen_string_literal: true

require "mighost"

namespace :mighost do
  desc "Show available commands"
  task :help do
    puts <<~HELP
      Mighost - Rollback Rails migrations even when the file is missing

      Commands:
        rails mighost:status              Show orphaned migrations (in DB but no file)
        rails mighost:rollback            Rollback orphaned migrations (interactive)
        rails mighost:scan                Capture migrations + search git for orphans
        rails mighost:list (ls)           List stored migration records
        rails mighost:dismiss             Dismiss orphans (interactive, or VERSION=x)
        rails mighost:undismiss           Restore dismissed migrations
        rails mighost:dismissed           List dismissed migrations
        rails mighost:cleanup             Remove stale records

      Options:
        VERSION=x        Target specific version (rollback, dismiss, undismiss)
        VERSION=a..b     Version range: a to b inclusive
        VERSION=..b      All versions up to b
        VERSION=a..      All versions from a onwards
        RESCAN=1         Force re-capture all snapshots (scan)
        FORCE=1          Skip confirmations
        OLD=1            Dismiss only old unrecoverable migrations (dismiss)
        SHOW_DISMISSED=1 Include dismissed in status
        LIMIT=N          Limit output rows (list)
        DEBUG=1          Verbose output (status)

      Typical workflow:
        1. rails mighost:scan       # First time setup
        2. rails mighost:status     # Check for orphaned migrations
        3. rails mighost:rollback   # Rollback interactively
        4. rails mighost:dismiss    # Dismiss unrecoverable orphans

    HELP
  end

  desc "Show orphaned migrations (in DB but no file). DEBUG=1, SHOW_DISMISSED=1"
  task status: :environment do
    ui = Mighost.ui
    Mighost::OrphanDetector.debug = ENV["DEBUG"] == "1"
    show_dismissed = ENV["SHOW_DISMISSED"] == "1"

    orphans = Mighost::API.orphaned_migrations(include_dismissed: show_dismissed)
    ui.render_orphans(orphans)

    unless show_dismissed
      dismissed_count = Mighost::API.dismissed_count
      ui.hint "#{dismissed_count} dismissed migration(s) hidden. Use SHOW_DISMISSED=1 to show." if dismissed_count.positive?
    end

    if Mighost.configuration.hide_superseded
      ui.hint "Superseded migrations are hidden (config.hide_superseded)."
    end

    non_recoverable = orphans.reject(&:recoverable?)
    if non_recoverable.any? && Mighost::OrphanDetector.branch_changed?
      ui.hint "Branch changed since last scan. Run 'rails mighost:scan' to update recovery info."
    end
  end

  desc "Rollback orphaned migrations. VERSION=xxx for specific, FORCE=1 to skip confirmation"
  task rollback: :environment do
    ui = Mighost.ui
    version = ENV["VERSION"]
    force = ENV["FORCE"] == "1"

    if version
      begin
        Mighost::API.rollback_version!(version)
        ui.success "Successfully rolled back migration #{version}"
      rescue Mighost::SnapshotNotFound
        ui.error "No record found for version #{version}"
      rescue Mighost::RollbackFailed => e
        ui.error "Failed to rollback: #{e.message}"
      end
      next
    end

    orphans = Mighost::API.orphaned_migrations.select(&:recoverable?)

    if orphans.empty?
      ui.info "No recoverable orphaned migrations found."
      next
    end

    ui.render_recoverable_list(orphans)

    results = {rolled_back: [], failed: [], skipped: []}
    rollback_all = force

    orphans.each do |orphan|
      unless rollback_all
        response = ui.confirm_each?(orphan)
        case response
        when :quit
          ui.warning "Aborted."
          break
        when :no
          results[:skipped] << orphan.version
          next
        when :all
          rollback_all = true
        end
      end

      begin
        Mighost::API.rollback_version!(orphan.version)
        results[:rolled_back] << orphan.version
        ui.success "  Rolled back #{orphan.version}"
      rescue => e
        results[:failed] << {version: orphan.version, error: e.message}
        ui.error "  Failed: #{e.message}"
      end
    end

    ui.info "Done: #{results[:rolled_back].size} rolled back, #{results[:skipped].size} skipped, #{results[:failed].size} failed"
  end

  desc "Scan and capture existing migrations, search git for orphans. RESCAN=1 to force re-capture all"
  task scan: :environment do
    ui = Mighost.ui
    result = Mighost::API.scan!(rescan: ENV["RESCAN"] == "1")

    ui.render_scan_details(result[:details])
    ui.render_scan_results(
      captured: result[:captured],
      git_recovered: result[:git_recovered],
      worktree_recovered: result[:worktree_recovered],
      branch: result[:branch],
      sha: result[:sha]
    )
  end

  desc "List stored migration records (LIMIT=N to limit)"
  task list: :environment do
    limit = ENV["LIMIT"]&.to_i
    records = Mighost::API.all_snapshots
    total_count = records.count
    display_records = limit&.positive? ? records.first(limit) : records

    Mighost.ui.render_records(display_records, limit: limit, total_count: total_count)
  end

  task ls: :list

  desc "Clean up stale records for migrations no longer in schema_migrations"
  task cleanup: :environment do
    ui = Mighost.ui
    Mighost::Snapshot.ensure_table_exists!
    migrated_versions = Mighost::Base.connection
      .select_values("SELECT version FROM schema_migrations")
      .map(&:to_s)

    all_record_versions = Mighost::Snapshot.all_versions
    stale_versions = all_record_versions - migrated_versions

    if stale_versions.empty?
      ui.info "No stale records to clean up."
      next
    end

    ui.warning "Found #{stale_versions.count} stale record(s):"
    stale_versions.each { |v| ui.info "  #{v}" }

    unless ENV["FORCE"] == "1"
      unless ui.confirm?("Delete these records?")
        ui.warning "Aborted."
        next
      end
    end

    stale_versions.each { |v| Mighost::Snapshot.delete_by_version(v) }
    ui.success "Cleaned up #{stale_versions.count} record(s)."
  end

  desc "Dismiss orphaned migrations (hide from status). VERSION=x, VERSION=a..b (range), OLD=1"
  task dismiss: :environment do
    ui = Mighost.ui
    version_param = ENV["VERSION"]
    old_only = ENV["OLD"] == "1"

    orphans = Mighost::API.orphaned_migrations

    if old_only
      orphans = orphans.select(&:suggested_for_dismiss?)
      if orphans.empty?
        ui.info "No old unrecoverable migrations to dismiss."
        ui.hint "Migrations must be older than 6 months and not recoverable."
        next
      end
    end

    if orphans.empty?
      ui.info "No orphaned migrations to dismiss."
      next
    end

    orphan_versions = orphans.map(&:version).sort
    orphan_map = orphans.index_by(&:version)

    to_dismiss = if version_param
      Mighost::Formatting.parse_version_range(version_param, orphan_versions)
    else
      orphan_versions
    end

    if to_dismiss.empty?
      ui.warning "No matching orphaned migrations found."
      next
    end

    ui.render_dismiss_preview(to_dismiss, orphan_map)

    results = {dismissed: [], skipped: []}
    dismiss_all = ENV["FORCE"] == "1"

    to_dismiss.each do |version|
      orphan = orphan_map[version]
      name = orphan&.filename || "(unknown)"

      unless dismiss_all
        response = ui.confirm_dismiss?(version, name)
        case response
        when :quit
          ui.warning "Aborted."
          break
        when :no
          results[:skipped] << version
          next
        when :all
          remaining = to_dismiss[to_dismiss.index(version)..]
          ui.render_dismiss_remaining(remaining, orphan_map)

          if ui.confirm?("Confirm dismiss all #{remaining.count}?")
            remaining.each do |v|
              Mighost::API.dismiss(v)
              results[:dismissed] << v
            end
            ui.success "Dismissed #{remaining.count} migration(s)."
          else
            ui.warning "Aborted."
          end
          break
        end
      end

      Mighost::API.dismiss(version)
      results[:dismissed] << version
      ui.success "  Dismissed #{version}"
    end

    ui.info "Done: #{results[:dismissed].size} dismissed, #{results[:skipped].size} skipped"
  end

  desc "Undismiss migrations (restore visibility). VERSION=x or VERSION=a..b"
  task undismiss: :environment do
    ui = Mighost.ui
    version_param = ENV["VERSION"]

    unless version_param
      ui.error "VERSION required. Use same format as dismiss."
      next
    end

    dismissed = Mighost::Snapshot.dismissed_versions.sort

    if dismissed.empty?
      ui.info "No dismissed migrations."
      next
    end

    targets = Mighost::Formatting.parse_version_range(version_param, dismissed)

    if targets.empty?
      ui.warning "No matching dismissed migrations found."
      next
    end

    targets.each do |version|
      Mighost::API.undismiss(version)
      ui.success "Undismissed #{version}"
    end

    ui.info "Restored #{targets.count} migration(s) to status output."
  end

  desc "List dismissed migrations"
  task dismissed: :environment do
    dismissed = Mighost::Snapshot.dismissed_versions.sort

    if dismissed.empty?
      Mighost.ui.info "No dismissed migrations."
      next
    end

    dismissed_snapshots = dismissed.map { |v| [v, Mighost::API.find_snapshot(v)] }
    Mighost.ui.render_dismissed_list(dismissed_snapshots)
  end
end
