# frozen_string_literal: true

require "tty-table"
require "pastel"

module Mighost
  module UI
    class << self
      def pastel
        @pastel ||= Pastel.new(enabled: $stdout.tty?)
      end

      def render_orphans_table(orphans)
        if orphans.empty?
          info "No orphaned migrations found."
          return
        end

        # Partition into actionable and suggested for dismissal
        actionable, suggested = orphans.partition(&:actionable?)

        recoverable_count = orphans.count(&:recoverable?)
        suggested_count = suggested.count

        # Header with counts
        header_parts = ["#{orphans.count} total", "#{recoverable_count} recoverable"]
        header_parts << "#{suggested_count} suggested to dismiss" if suggested_count.positive?
        puts "\n#{pastel.cyan("Orphaned Migrations")} (#{header_parts.join(", ")}):\n\n"

        header = [
          pastel.cyan("Version"),
          pastel.cyan("Branch"),
          pastel.cyan("SHA"),
          pastel.cyan("Recovery"),
          pastel.cyan("Name"),
          pastel.cyan("Age")
        ]

        # Build all rows
        rows = []
        actionable.each { |o| rows << build_orphan_row(o, dim: false) }
        suggested.each { |o| rows << build_orphan_row(o, dim: true) }

        # Render single table
        table = TTY::Table.new(header: header, rows: rows)
        table_output = table.render(:unicode, padding: [0, 1], resize: true) { |renderer|
          renderer.border.style = :dim
          renderer.width = terminal_width
        }

        # If we have both sections, insert a separator line after actionable rows
        if actionable.any? && suggested.any?
          lines = table_output.split("\n")
          # Find where to insert: top border (1) + header row (1) + header separator (1) + actionable rows
          insert_after = 3 + actionable.count
          # Get visual width from first line (strip ANSI codes)
          first_line = lines.first || ""
          visual_width = first_line.gsub(/\e\[[0-9;]*m/, "").length
          # Build separator that matches table width
          label = " Suggested to Dismiss (#{suggested.count} old, unrecoverable) "
          padding_needed = visual_width - 2 - label.length  # -2 for ├ and ┤
          left_pad = 2
          right_pad = [padding_needed - left_pad, 0].max
          separator_line = "├#{"─" * left_pad}#{label}#{"─" * right_pad}┤"
          lines.insert(insert_after, pastel.dim(separator_line))
          puts lines.join("\n")
        else
          puts table_output
        end

        # Show tips
        if suggested_count.positive?
          puts "\n#{pastel.cyan("Tip:")} Run 'rails mighost:dismiss OLD=1' to bulk-dismiss the #{suggested_count} old migrations."
        end

        if recoverable_count.positive?
          puts "\n#{pastel.cyan("Tip:")} Run 'rails mighost:rollback' to rollback recoverable migrations."
        end
      end

      def build_orphan_row(orphan, dim: false)
        version = format_version(orphan.version)
        name = format_name(orphan.filename)
        recovery = format_recovery(orphan.recovery_source)
        branch = truncate(orphan.branch_name || "-", 30)
        sha = orphan.git_sha || "-"
        age = format_age(orphan.created_at)

        if orphan.recoverable?
          [version, branch, sha, recovery, name, age]
        elsif dim
          [
            pastel.dim(version),
            pastel.dim(branch),
            pastel.dim(sha),
            recovery,
            pastel.dim(name),
            pastel.dim(age)
          ]
        else
          [
            pastel.dim(version),
            pastel.dim(branch),
            pastel.dim(sha),
            recovery,
            pastel.dim(name),
            pastel.dim(age)
          ]
        end
      end

      def render_records_table(records, limit: nil, total_count: nil)
        if records.empty?
          info "No migration records stored."
          return
        end

        count_text = if limit && total_count && total_count > records.count
                       "#{records.count} of #{total_count}"
                     else
                       records.count.to_s
                     end

        header = [
          pastel.cyan("Version"),
          pastel.cyan("Branch"),
          pastel.cyan("SHA"),
          pastel.cyan("Captured"),
          pastel.cyan("Name")
        ]

        rows = records.map do |record|
          version = format_version(record.version)
          name = format_name(record.filename)
          branch = truncate(record.branch_name || "-", 25)
          sha = record.git_sha || "-"
          captured = format_captured_at(record.migrated_at)

          [version, branch, sha, captured, name]
        end

        table = TTY::Table.new(header: header, rows: rows)

        output = []
        output << "\n#{pastel.cyan("Migration Records")} (#{count_text}):\n\n"
        output << table.render(:unicode, padding: [0, 1], resize: true) { |renderer|
          renderer.border.style = :dim
          renderer.width = terminal_width
        }

        # Use pager if output is large and stdout is a TTY
        if $stdout.tty? && records.size > 30 && !limit
          pager = ENV["PAGER"] || "less -R"
          IO.popen(pager, "w") { |io| io.puts output.join }
        else
          puts output.join
        end
      end

      def render_recoverable_list(orphans)
        puts "\n#{pastel.cyan("Recoverable orphaned migrations:")}"
        orphans.each do |orphan|
          name = orphan.filename || "(unknown)"
          puts "  #{pastel.dim(orphan.version)} - #{name}"
        end
      end

      def render_rollback_results(results)
        if results[:rolled_back].any?
          success "\nSuccessfully rolled back:"
          results[:rolled_back].each { |v| puts "  #{pastel.green(v)}" }
        end

        if results[:failed].any?
          error "\nFailed to rollback:"
          results[:failed].each { |f| puts "  #{pastel.red(f[:version])}: #{f[:error]}" }
        end
      end

      def confirm?(prompt)
        print "\n#{pastel.yellow(prompt)} [y/N] "
        response = $stdin.gets.chomp.downcase
        response == "y"
      end

      # Interactive per-item confirmation
      # Returns :yes, :no, :all, or :quit
      def confirm_each?(orphan)
        name = orphan.filename || "(unknown)"
        version = format_version(orphan.version)
        recovery = format_recovery(orphan.recovery_source)

        print "\nRollback #{pastel.cyan(version)} #{name} [#{recovery}]? "
        print "[#{pastel.green("y")}es/#{pastel.red("n")}o/#{pastel.green("a")}ll/#{pastel.red("q")}uit] "

        response = $stdin.gets.chomp.downcase
        case response
        when "y", "yes" then :yes
        when "n", "no", "" then :no
        when "a", "all" then :all
        when "q", "quit" then :quit
        else :no
        end
      end

      # Interactive confirmation for dismiss
      # Returns :yes, :no, :all, or :quit
      def confirm_dismiss?(version, name)
        formatted_version = format_version(version)

        print "\nDismiss #{pastel.cyan(formatted_version)} #{name}? "
        print "[#{pastel.green("y")}es/#{pastel.red("n")}o/#{pastel.green("a")}ll/#{pastel.red("q")}uit] "

        response = $stdin.gets.chomp.downcase
        case response
        when "y", "yes" then :yes
        when "n", "no", "" then :no
        when "a", "all" then :all
        when "q", "quit" then :quit
        else :no
        end
      end

      def success(msg)
        puts pastel.green(msg)
      end

      def error(msg)
        puts pastel.red(msg)
      end

      def warning(msg)
        puts pastel.yellow(msg)
      end

      def info(msg)
        puts pastel.cyan(msg)
      end

      def hint(msg)
        puts pastel.dim("Hint: #{msg}")
      end

      def format_version(version)
        if version =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/
          "#{$1}-#{$2}-#{$3} #{$4}:#{$5}"
        else
          version
        end
      end

      private

      def format_name(filename)
        return "(unknown)" unless filename

        name = filename.sub(/^\d+_/, "").sub(/\.rb$/, "")
        truncate(name, 40)
      end

      def format_recovery(source)
        case source
        when :snapshot then pastel.green("snapshot")
        when :git then pastel.yellow("git")
        else pastel.dim("-")
        end
      end

      def format_captured_at(value)
        case value
        when String then value[0, 10]
        when Time then value.strftime("%Y-%m-%d")
        else "-"
        end
      end

      def truncate(str, max_length)
        return str if str.length <= max_length

        "#{str[0, max_length - 3]}..."
      end

      def format_age(created_at)
        return "-" unless created_at

        seconds = Time.now - created_at
        return "-" if seconds < 0

        days = (seconds / 86400).to_i
        months = (days / 30.0).to_i
        years = (days / 365.0).to_i

        if years >= 1
          remaining_months = ((days - years * 365) / 30.0).to_i
          if remaining_months.positive?
            "#{years}y #{remaining_months}mo"
          else
            "#{years}y"
          end
        elsif months >= 1
          "#{months}mo"
        elsif days >= 1
          "#{days}d"
        else
          "<1d"
        end
      end

      def terminal_width
        max_width = 120
        return max_width unless $stdout.tty?

        require "io/console"
        actual = IO.console&.winsize&.last || max_width
        [actual, max_width].min
      rescue LoadError
        max_width
      end
    end
  end
end
