# frozen_string_literal: true

module Mighost
  module Formatting
    module_function

    def format_version(version)
      if version =~ /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/
        "#{$1}-#{$2}-#{$3} #{$4}:#{$5}"
      else
        version.to_s
      end
    end

    def format_name(filename)
      return "(unknown)" unless filename

      name = filename.sub(/^\d+_/, "").sub(/\.rb$/, "")
      truncate(name, 40)
    end

    def format_recovery(source)
      case source
      when :snapshot then "snapshot"
      when :branch then "git"
      when :worktree then "worktree"
      else "-"
      end
    end

    def format_captured_at(value)
      case value
      when String then value[0, 10]
      when Time then value.strftime("%Y-%m-%d")
      else "-"
      end
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

    def truncate(str, max_length)
      return str if str.length <= max_length

      "#{str[0, max_length - 3]}..."
    end

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
        available_versions.select { |v| v.between?(lower, upper) }
      else # single version
        available_versions.include?(param) ? [param] : []
      end
    end
  end
end
