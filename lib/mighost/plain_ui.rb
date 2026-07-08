# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require_relative "formatting"

module Mighost
  # PlainUI is the default UI adapter for mighost.
  # It outputs plain, uncolored text suitable for any terminal.
  #
  # To provide custom (rich) output, replace this adapter:
  #   Mighost.ui = YourCustomUI.new
  #
  # Adapter interface:
  #   render_orphans(orphans)
  #   render_records(records, limit:, total_count:)
  #   render_recoverable_list(orphans)
  #   render_scan_details(details)
  #   render_scan_results(captured:, git_recovered:, worktree_recovered:, branch:, sha:)
  #   render_dismiss_preview(versions, orphan_map)
  #   render_dismissed_list(dismissed_snapshots)
  #   confirm?(prompt) -> Boolean
  #   confirm_each?(orphan) -> :yes, :no, :all, :quit
  #   confirm_dismiss?(version, name) -> :yes, :no, :all, :quit
  #   success(msg), error(msg), warning(msg), info(msg), hint(msg)
  #
  class PlainUI
    include Formatting

    def render_orphans(orphans)
      if orphans.empty?
        info "No orphaned migrations found."
        return
      end

      actionable, suggested = orphans.partition(&:actionable?)

      recoverable_count = orphans.count(&:recoverable?)
      suggested_count = suggested.count

      header_parts = ["#{orphans.count} total", "#{recoverable_count} recoverable"]
      header_parts << "#{suggested_count} suggested to dismiss" if suggested_count.positive?
      puts "\nOrphaned migrations (#{header_parts.join(", ")}):\n\n"

      actionable.each { |o| puts "  #{orphan_line(o)}" }

      if actionable.any? && suggested.any?
        puts "\n  Suggested to dismiss (#{suggested.count} old, unrecoverable):\n"
      end

      suggested.each { |o| puts "  #{orphan_line(o)}" }

      if suggested_count.positive?
        puts "\nTip: Run 'rails mighost:dismiss OLD=1' to bulk-dismiss the #{suggested_count} old migrations."
      end

      if recoverable_count.positive?
        puts "\nTip: Run 'rails mighost:rollback' to rollback recoverable migrations."
      end
    end

    def render_records(records, limit: nil, total_count: nil)
      if records.empty?
        info "No migration records stored."
        return
      end

      count_text = if limit && total_count && total_count > records.count
        "#{records.count} of #{total_count}"
      else
        records.count.to_s
      end

      output = []
      output << "\nMigration records (#{count_text}):\n\n"
      records.each do |record|
        version = format_version(record.version)
        name = format_name(record.filename)
        branch = truncate(record.branch_name || "-", 25)
        sha = record.git_sha || "-"
        captured = format_captured_at(record.migrated_at)
        author = truncate(record.author_name || "-", 20)

        output << "  #{version}  #{name.ljust(42)}  #{branch.ljust(27)}  #{sha.ljust(14)}  #{captured}  #{author}\n"
      end

      text = output.join

      if $stdout.tty? && records.size > 30 && !limit
        pager = ENV["PAGER"] || "less"
        IO.popen(pager, "w") { |io| io.puts text }
      else
        print text
      end
    end

    def render_recoverable_list(orphans)
      puts "\nRecoverable orphaned migrations:"
      orphans.each do |orphan|
        name = orphan.filename || "(unknown)"
        puts "  #{orphan.version} - #{name}"
      end
    end

    def render_scan_details(details)
      details.each do |detail|
        case detail[:type]
        when :captured
          info "Captured: #{detail[:filename]}"
        when :git_recovered
          info "Git recovered: #{detail[:filename]} (from #{detail[:branch]})"
        when :worktree_recovered
          info "Worktree recovered: #{detail[:filename]} (from #{detail[:branch]})"
        end
      end
    end

    def render_scan_results(captured:, git_recovered:, worktree_recovered:, branch:, sha:)
      puts ""
      success "Scan complete:"
      info "  Captured #{captured} migration(s) from files"
      info "  Recovered #{git_recovered} orphan(s) from git history"
      info "  Recovered #{worktree_recovered} orphan(s) from worktrees" if worktree_recovered > 0
      info "  Context: #{branch} @ #{sha}"
    end

    def render_dismiss_preview(versions, orphan_map)
      puts "\nFound #{versions.count} orphaned migration(s) to dismiss:\n"
      preview_count = 10
      versions.first(preview_count).each do |v|
        puts "  #{v}  (#{format_version(v)})"
      end
      if versions.count > preview_count
        remaining = versions.count - preview_count
        puts "  ... and #{remaining} more up to #{format_version(versions.last)}"
      end
      puts ""
    end

    def render_dismiss_remaining(versions, orphan_map)
      puts "\nDismissing all remaining:"
      versions.each do |v|
        o = orphan_map[v]
        puts "  #{v} - #{o&.filename || "(unknown)"}"
      end
    end

    def render_dismissed_list(dismissed_snapshots)
      puts "\nDismissed migrations (#{dismissed_snapshots.count}):\n\n"
      dismissed_snapshots.each do |version, snapshot|
        name = snapshot&.filename.presence || "(unknown)"
        dismissed_at = snapshot&.dismissed_at
        date_str = dismissed_at ? " (dismissed #{dismissed_at[0, 10]})" : ""
        puts "  #{version} - #{name}#{date_str}"
      end
      puts "\nTip: Use 'rails mighost:undismiss VERSION=x' to restore."
    end

    def confirm?(prompt)
      print "\n#{prompt} [y/N] "
      response = $stdin.gets.chomp.downcase
      response == "y"
    end

    def confirm_each?(orphan)
      name = orphan.filename || "(unknown)"
      version = format_version(orphan.version)
      recovery = format_recovery(orphan.recovery_source)

      print "\nRollback #{version} #{name} [#{recovery}]? [y/n/a/q] "
      parse_multi_choice
    end

    def confirm_dismiss?(version, name)
      print "\nDismiss #{format_version(version)} #{name}? [y/n/a/q] "
      parse_multi_choice
    end

    def success(msg)
      puts msg
    end

    def error(msg)
      puts msg
    end

    def warning(msg)
      puts msg
    end

    def info(msg)
      puts msg
    end

    def hint(msg)
      puts "Hint: #{msg}"
    end

    private

    def parse_multi_choice
      response = $stdin.gets.chomp.downcase
      case response
      when "y", "yes" then :yes
      when "n", "no", "" then :no
      when "a", "all" then :all
      when "q", "quit" then :quit
      else :no
      end
    end

    def orphan_line(orphan)
      version = orphan.version
      name = format_name(orphan.filename)
      recovery = orphan.recoverable? ? "recoverable (#{format_recovery(orphan.recovery_source)})" : "not recoverable"
      branch = orphan.branch_name ? "branch:#{truncate(orphan.branch_name, 30)}" : ""
      author = orphan.author_name ? "author:#{truncate(orphan.author_name, 20)}" : ""

      parts = [version, name.ljust(42), recovery.ljust(24)]
      parts << branch unless branch.empty?
      parts << author unless author.empty?
      parts.join("  ")
    end
  end
end
