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

        recoverable_count = orphans.count(&:recoverable?)
        puts "\n#{pastel.cyan("Orphaned Migrations")} (#{orphans.count} total, #{recoverable_count} recoverable):\n\n"

        header = [
          pastel.cyan("Version"),
          pastel.cyan("Branch"),
          pastel.cyan("SHA"),
          pastel.cyan("Recovery"),
          pastel.cyan("Name")
        ]

        rows = orphans.map do |orphan|
          version = format_version(orphan.version)
          name = format_name(orphan.filename)
          recovery = format_recovery(orphan.recovery_source)
          branch = truncate(orphan.branch_name || "-", 30)
          sha = orphan.git_sha || "-"

          if orphan.recoverable?
            [version, branch, sha, recovery, name]
          else
            [
              pastel.dim(version),
              pastel.dim(branch),
              pastel.dim(sha),
              recovery,
              pastel.dim(name)
            ]
          end
        end

        table = TTY::Table.new(header: header, rows: rows)
        puts table.render(:unicode, padding: [0, 1], resize: true) { |renderer|
          renderer.border.style = :dim
          renderer.width = terminal_width
        }

        puts "\n#{pastel.cyan("Tip:")} Run 'rails mighost:rollback' to rollback recoverable migrations."
      end

      def render_snapshots_table(snapshots, limit: nil, total_count: nil)
        if snapshots.empty?
          info "No snapshots stored."
          return
        end

        count_text = if limit && total_count && total_count > snapshots.count
                       "#{snapshots.count} of #{total_count}"
                     else
                       snapshots.count.to_s
                     end

        header = [
          pastel.cyan("Version"),
          pastel.cyan("Branch"),
          pastel.cyan("SHA"),
          pastel.cyan("Captured"),
          pastel.cyan("Name")
        ]

        rows = snapshots.map do |snapshot|
          version = format_version(snapshot.version)
          name = format_name(snapshot.filename)
          branch = truncate(snapshot.branch_name || "-", 25)
          sha = snapshot.git_sha || "-"
          captured = format_captured_at(snapshot.migrated_at)

          [version, branch, sha, captured, name]
        end

        table = TTY::Table.new(header: header, rows: rows)

        output = []
        output << "\n#{pastel.cyan("Stored Snapshots")} (#{count_text}):\n\n"
        output << table.render(:unicode, padding: [0, 1], resize: true) { |renderer|
          renderer.border.style = :dim
          renderer.width = terminal_width
        }

        # Use pager if output is large and stdout is a TTY
        if $stdout.tty? && snapshots.size > 30 && !limit
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

      private

      def format_version(version)
        if version =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/
          "#{$1}-#{$2}-#{$3} #{$4}:#{$5}"
        else
          version
        end
      end

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
