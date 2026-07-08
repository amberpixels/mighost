# frozen_string_literal: true

require "shellwords"
require "active_support/core_ext/object/blank"
require_relative "git_metadata"

module Mighost
  # Searches other git worktrees for migration files that exist on disk
  # but haven't been committed yet (invisible to git log --all)
  module WorktreeRecovery
    class << self
      # Find migration file in other worktrees
      # Returns { content:, filename:, branch:, worktree_path: } or nil
      def find_migration(version)
        return nil unless GitMetadata.git_available?

        worktrees = list_worktrees
        return nil if worktrees.empty?

        current_root = git_root
        return nil unless current_root

        worktrees.each do |wt|
          next if wt[:path] == current_root

          result = find_in_worktree(wt, version)
          return result if result
        end

        nil
      end

      # List all git worktrees with their paths and branches
      def list_worktrees
        output = `git worktree list --porcelain 2>/dev/null`.strip
        return [] if output.empty?

        worktrees = []
        current = {}

        output.each_line do |line|
          line = line.chomp
          if line.start_with?("worktree ")
            current = {path: line.sub("worktree ", "")}
          elsif line.start_with?("branch ")
            ref = line.sub("branch ", "")
            # refs/heads/feature-branch -> feature-branch
            current[:branch] = ref.sub(%r{^refs/heads/}, "")
          elsif line == "detached"
            current[:branch] = nil
          elsif line.empty? && current[:path]
            worktrees << current
            current = {}
          end
        end

        # Last entry (no trailing blank line)
        worktrees << current if current[:path]

        worktrees
      end

      private

      def find_in_worktree(wt, version)
        pattern = File.join(wt[:path], "db", "migrate", "#{version}_*.rb")
        matches = Dir.glob(pattern)
        return nil if matches.empty?

        file = matches.first
        content = File.read(file)

        author_name, author_email = worktree_git_user(wt[:path])

        {
          content: content,
          filename: File.basename(file),
          branch: wt[:branch],
          worktree_path: wt[:path],
          author_name: author_name,
          author_email: author_email
        }
      rescue => e
        warn "[Mighost] Failed to read worktree migration #{file}: #{e.message}"
        nil
      end

      def worktree_git_user(path)
        escaped = Shellwords.escape(path)
        name = `git -C #{escaped} config user.name 2>/dev/null`.strip
        email = `git -C #{escaped} config user.email 2>/dev/null`.strip
        [name.presence, email.presence]
      end

      def git_root
        result = `git rev-parse --show-toplevel 2>/dev/null`.strip
        result.empty? ? nil : result
      end
    end
  end
end
