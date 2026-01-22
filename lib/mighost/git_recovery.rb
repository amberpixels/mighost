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
          commit_date: result[:date]
        }
      end

      def git_available?
        return @git_available if defined?(@git_available)

        @git_available = system("git rev-parse --git-dir > /dev/null 2>&1")
      end

      private

      def find_latest_commit_with_file(pattern)
        # Use git log --all --source to search across ALL refs in a single command
        # --source shows which ref was used to reach the commit
        # --name-only includes the filename in output
        output = `git log --all --source -1 --format='%H|%aI|%S' --name-only -- #{shell_escape(pattern)} 2>/dev/null`.strip
        return nil if output.empty?

        lines = output.split("\n").map(&:strip).reject(&:empty?)
        return nil if lines.empty?

        # First non-empty line: commit info (sha|date|source_ref)
        commit_line = lines[0]
        sha, date_str, source_ref = commit_line.split("|", 3)
        return nil unless sha && date_str

        # Second non-empty line: the file path
        file_path = lines[1]
        return nil if file_path.nil? || file_path.empty?

        date = Time.parse(date_str) rescue nil
        return nil unless date

        # Clean up the source ref (remove refs/heads/, refs/remotes/, etc.)
        branch = clean_ref_name(source_ref)

        {
          sha: sha,
          path: file_path,
          branch: branch,
          date: date
        }
      end

      def clean_ref_name(ref)
        return nil if ref.nil? || ref.empty?

        ref = ref.strip
        ref = ref.sub(%r{^refs/remotes/}, "")
        ref = ref.sub(%r{^refs/heads/}, "")
        ref = ref.sub(%r{^origin/}, "")
        ref.empty? ? nil : ref
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
