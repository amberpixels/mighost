# frozen_string_literal: true

module Mighost
  class GitMetadata
    class << self
      def current_branch
        return nil unless git_available?

        result = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
        result.empty? ? nil : result
      end

      def current_sha
        return nil unless git_available?

        result = `git rev-parse HEAD 2>/dev/null`.strip
        result.empty? ? nil : result[0, 12] # Short SHA
      end

      def git_available?
        return @git_available if defined?(@git_available)

        @git_available = system("git rev-parse --git-dir > /dev/null 2>&1")
      end

      def reset!
        remove_instance_variable(:@git_available) if defined?(@git_available)
      end
    end
  end
end
