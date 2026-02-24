# frozen_string_literal: true

require "terminal-table"

module Mighost
  module UI
    # Minimal ANSI color helpers (replaces Pastel gem)
    module Color
      CODES = { red: 31, green: 32, yellow: 33, cyan: 36, dim: 2 }.freeze

      class << self
        def enabled?
          @enabled = $stdout.tty? if @enabled.nil?
          @enabled
        end

        CODES.each do |name, code|
          define_method(name) do |text|
            enabled? ? "\e[#{code}m#{text}\e[0m" : text.to_s
          end
        end
      end
    end

    class << self
      def color
        Color
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
        puts "\n#{color.cyan("Orphaned Migrations")} (#{header_parts.join(", ")}):\n\n"

        headings = %w[Version Branch SHA Recovery Name Age].map { |h| color.cyan(h) }

        # Build all rows
        rows = []
        actionable.each { |o| rows << build_orphan_row(o, dim: false) }

        if actionable.any? && suggested.any?
          rows << :separator
          rows << [{ value: color.dim(" Suggested to Dismiss (#{suggested.count} old, unrecoverable)"), colspan: 6 }]
          rows << :separator
        end

        suggested.each { |o| rows << build_orphan_row(o, dim: true) }

        table = Terminal::Table.new(headings: headings, rows: rows, style: { border: :unicode })

        puts table

        # Show tips
        if suggested_count.positive?
          puts "\n#{color.cyan("Tip:")} Run 'rails mighost:dismiss OLD=1' to bulk-dismiss the #{suggested_count} old migrations."
        end

        if recoverable_count.positive?
          puts "\n#{color.cyan("Tip:")} Run 'rails mighost:rollback' to rollback recoverable migrations."
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
        else
          [
            color.dim(version),
            color.dim(branch),
            color.dim(sha),
            recovery,
            color.dim(name),
            color.dim(age)
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

        headings = %w[Version Branch SHA Captured Name].map { |h| color.cyan(h) }

        rows = records.map do |record|
          version = format_version(record.version)
          name = format_name(record.filename)
          branch = truncate(record.branch_name || "-", 25)
          sha = record.git_sha || "-"
          captured = format_captured_at(record.migrated_at)

          [version, branch, sha, captured, name]
        end

        table = Terminal::Table.new(headings: headings, rows: rows, style: { border: :unicode })

        output = []
        output << "\n#{color.cyan("Migration Records")} (#{count_text}):\n\n"
        output << table.to_s

        # Use pager if output is large and stdout is a TTY
        if $stdout.tty? && records.size > 30 && !limit
          pager = ENV["PAGER"] || "less -R"
          IO.popen(pager, "w") { |io| io.puts output.join("\n") }
        else
          puts output.join("\n")
        end
      end

      def render_recoverable_list(orphans)
        puts "\n#{color.cyan("Recoverable orphaned migrations:")}"
        orphans.each do |orphan|
          name = orphan.filename || "(unknown)"
          puts "  #{color.dim(orphan.version)} - #{name}"
        end
      end

      def render_rollback_results(results)
        if results[:rolled_back].any?
          success "\nSuccessfully rolled back:"
          results[:rolled_back].each { |v| puts "  #{color.green(v)}" }
        end

        if results[:failed].any?
          error "\nFailed to rollback:"
          results[:failed].each { |f| puts "  #{color.red(f[:version])}: #{f[:error]}" }
        end
      end

      def confirm?(prompt)
        print "\n#{color.yellow(prompt)} [y/N] "
        response = $stdin.gets.chomp.downcase
        response == "y"
      end

      # Interactive per-item confirmation
      # Returns :yes, :no, :all, or :quit
      def confirm_each?(orphan)
        name = orphan.filename || "(unknown)"
        version = format_version(orphan.version)
        recovery = format_recovery(orphan.recovery_source)

        print "\nRollback #{color.cyan(version)} #{name} [#{recovery}]? "
        print "[#{color.green("y")}es/#{color.red("n")}o/#{color.green("a")}ll/#{color.red("q")}uit] "

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

        print "\nDismiss #{color.cyan(formatted_version)} #{name}? "
        print "[#{color.green("y")}es/#{color.red("n")}o/#{color.green("a")}ll/#{color.red("q")}uit] "

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
        puts color.green(msg)
      end

      def error(msg)
        puts color.red(msg)
      end

      def warning(msg)
        puts color.yellow(msg)
      end

      def info(msg)
        puts color.cyan(msg)
      end

      def hint(msg)
        puts color.dim("Hint: #{msg}")
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
        when :snapshot then color.green("snapshot")
        when :git then color.yellow("git")
        else color.dim("-")
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
    end
  end
end
