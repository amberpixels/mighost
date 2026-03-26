# frozen_string_literal: true

module Mighost
  # Searches git history to find migration files that exist in other branches/commits
  module GitRecovery
    class << self
      # Find migration file content from git history
      # Returns { content:, filename:, branch:, sha:, commit_date: } or nil
      def find_migration(version)
        return nil unless git_available?

        # Search for the migration file across all branches using --all
        pattern = "db/migrate/#{version}_*.rb"

        result = find_latest_commit_with_file(pattern)
        return nil unless result

        content = get_file_content(result[:sha], result[:path])
        return nil unless content

        {
          content: content,
          filename: File.basename(result[:path]),
          branch: result[:branch],
          sha: result[:sha][0, 12],
          commit_date: result[:date],
          author_name: result[:author_name],
          author_email: result[:author_email]
        }
      end

      def git_available?
        return @git_available if defined?(@git_available)

        @git_available = system("git rev-parse --git-dir > /dev/null 2>&1")
      end

      private

      def find_latest_commit_with_file(pattern)
        # Use git log --all to search across ALL refs in a single command
        # %D shows decorated refs (branches/tags pointing to commit)
        # --name-only includes the filename in output
        fmt = "%H\t%aI\t%D\t%aN\t%aE"
        cmd = "git log --all -1 --format='#{fmt}' --name-only -- #{shell_escape(pattern)} 2>/dev/null"
        output = `#{cmd}`.strip
        return nil if output.empty?

        lines = output.split("\n").map(&:strip).reject(&:empty?)
        return nil if lines.empty?

        # First non-empty line: commit info (sha\tdate\tdecorated_refs\tauthor_name\tauthor_email)
        commit_line = lines[0]
        sha, date_str, decorated_refs, author_name, author_email = commit_line.split("\t", 5)
        return nil unless sha && date_str

        # Second non-empty line: the file path
        file_path = lines[1]
        return nil if file_path.nil? || file_path.empty?

        date = Time.parse(date_str) rescue nil
        return nil unless date

        # Extract branch name from decorated refs (may be empty if commit is not a branch tip)
        branch = extract_branch_from_decorated_refs(decorated_refs)

        # If no branch found from decoration, try to find which branch contains this commit
        branch ||= find_branch_containing_commit(sha)

        {
          sha: sha,
          path: file_path,
          branch: branch,
          date: date,
          author_name: author_name,
          author_email: author_email
        }
      end

      def extract_branch_from_decorated_refs(refs)
        return nil if refs.nil? || refs.strip.empty?

        # Decorated refs look like: "HEAD -> main, origin/main, feature-branch"
        # Extract the first branch-like ref
        refs.split(",").each do |ref|
          ref = ref.strip
          ref = ref.sub(/^HEAD -> /, "")
          ref = ref.sub(%r{^origin/}, "")
          next if ref.empty? || ref.start_with?("tag:")

          return ref
        end
        nil
      end

      def find_branch_containing_commit(sha)
        # Find branches that contain this commit
        output = `git branch -a --contains #{sha} 2>/dev/null`.strip
        return nil if output.empty?

        # Parse output - each line is a branch name, * = current branch, + = worktree-checked-out
        lines = output.split("\n").map { |l| l.sub(/^[*+]?\s*/, "").strip }
        return nil if lines.empty?

        # Prefer local branches over remote, clean up names
        lines.each do |branch|
          next if branch.start_with?("remotes/")
          return branch
        end

        # Fall back to first remote branch, cleaned up
        first = lines.first
        first&.sub(%r{^remotes/origin/}, "")
      end

      def get_file_content(sha, path)
        content = `git show #{shell_escape(sha)}:#{shell_escape(path)} 2>/dev/null`
        return nil unless $?.success?

        content
      end

      def shell_escape(str)
        "'" + str.gsub("'", "'\\''") + "'"
      end
    end
  end
end
