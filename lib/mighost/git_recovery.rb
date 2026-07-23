# frozen_string_literal: true

require "time"
require "shellwords"
require_relative "git_metadata"

module Mighost
  # Searches git history to find migration files that exist in other branches/commits
  module GitRecovery
    class << self
      # Find migration file content from git history
      # Returns { content:, filename:, branch:, sha:, commit_date:, deleted_in_sha:, ... } or nil
      # branch: is a ref whose tip still has the file (remote refs keep their origin/ prefix),
      # or nil when the file is gone from every tip — then the deleted_* fields say where it went.
      def find_migration(version)
        return nil unless GitMetadata.git_available?

        # Search for the migration file across all branches using --all
        pattern = "db/migrate/#{version}_*.rb"

        result = find_latest_commit_with_file(pattern)
        return nil unless result

        content = get_file_content(result[:sha], result[:path])
        return nil unless content

        deletion = result[:branch] ? {} : deletion_metadata(pattern)

        {
          content: content,
          filename: File.basename(result[:path]),
          branch: result[:branch],
          sha: result[:sha][0, 12],
          commit_date: result[:date],
          author_name: result[:author_name],
          author_email: result[:author_email],
          deleted_in_sha: deletion[:deleted_in_sha],
          deleted_at: deletion[:deleted_at],
          deleted_by: deletion[:deleted_by]
        }
      end

      private

      def find_latest_commit_with_file(pattern)
        # Use git log --all to search across ALL refs in a single command
        # --name-only includes the filename in output
        # --diff-filter=d excludes deletion commits: without it, a migration whose
        # last touch was a delete resolves to the deleting commit, where the file
        # no longer exists and `git show` fails
        fmt = "%H\t%aI\t%aN\t%aE"
        cmd = "git log --all -1 --diff-filter=d --format='#{fmt}' --name-only -- #{Shellwords.escape(pattern)} 2>/dev/null"
        output = `#{cmd}`.strip
        return nil if output.empty?

        lines = output.split("\n").map(&:strip).reject(&:empty?)
        return nil if lines.empty?

        # First non-empty line: commit info (sha\tdate\tauthor_name\tauthor_email)
        commit_line = lines[0]
        sha, date_str, author_name, author_email = commit_line.split("\t", 4)
        return nil unless sha && date_str

        # Second non-empty line: the file path
        file_path = lines[1]
        return nil if file_path.nil? || file_path.empty?

        date = begin
          Time.parse(date_str)
        rescue
          nil
        end
        return nil unless date

        {
          sha: sha,
          path: file_path,
          branch: resolve_branch(sha, file_path),
          date: date,
          author_name: author_name,
          author_email: author_email
        }
      end

      # A branch is only a valid answer if its tip still has the file — a branch
      # that merely contains the commit sends the user somewhere the file isn't.
      def resolve_branch(sha, path)
        locals, remotes = branch_candidates(sha)
        locals = locals.select { |ref| file_at_tip?(ref, path) }
        remotes = remotes.select { |ref| file_at_tip?(ref, path) }
        return nil if locals.empty? && remotes.empty?

        current = GitMetadata.current_branch
        return current if current && locals.include?(current)

        default = default_branch
        return default if default && locals.include?(default)

        return locals.first unless locals.empty?

        return "origin/#{default}" if default && remotes.include?("origin/#{default}")

        remotes.first
      end

      # Refs containing the commit, most recently committed first.
      # Returns [local_names, remote_names] — remote names keep their origin/ prefix.
      def branch_candidates(sha)
        [contains_refs(sha, "refs/heads"), contains_refs(sha, "refs/remotes")]
      end

      def contains_refs(sha, namespace)
        cmd = "git for-each-ref #{namespace} --contains #{Shellwords.escape(sha)} " \
          "--sort=-committerdate --format='%(refname:short)' 2>/dev/null"
        `#{cmd}`.split("\n").map(&:strip).reject { |r| r.empty? || r.end_with?("/HEAD") }
      end

      def file_at_tip?(ref, path)
        system("git cat-file -e #{Shellwords.escape("#{ref}:#{path}")} 2>/dev/null")
      end

      def default_branch
        head = `git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null`.strip
        return head.sub(%r{^origin/}, "") unless head.empty?

        %w[main master].find do |name|
          system("git show-ref --verify --quiet #{Shellwords.escape("refs/heads/#{name}")}")
        end
      end

      # Where the file was deleted, for ghosts gone from every tip
      def deletion_metadata(pattern)
        fmt = "%H\t%aI\t%aN"
        cmd = "git log --all --diff-filter=D -1 --format='#{fmt}' -- #{Shellwords.escape(pattern)} 2>/dev/null"
        output = `#{cmd}`.strip
        return {} if output.empty?

        sha, date_str, author = output.split("\t", 3)
        date = begin
          Time.parse(date_str)
        rescue
          nil
        end

        {deleted_in_sha: sha && sha[0, 12], deleted_at: date, deleted_by: author}
      end

      def get_file_content(sha, path)
        content = `git show #{Shellwords.escape("#{sha}:#{path}")} 2>/dev/null`
        return nil unless $?.success?

        content
      end
    end
  end
end
