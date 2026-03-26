# frozen_string_literal: true

require "shellwords"
require_relative "snapshot"
require_relative "git_metadata"

module Mighost
  class Capturer
    attr_reader :version, :migration_path

    def initialize(version, migration_path)
      @version = version.to_s
      @migration_path = migration_path
    end

    def capture
      return unless Mighost.enabled?
      return unless Mighost.configuration.auto_capture
      return unless File.exist?(migration_path)

      content = File.read(migration_path)
      filename = File.basename(migration_path)

      attributes = {
        version: version,
        content: content,
        filename: filename
      }

      if Mighost.configuration.store_git_metadata
        attributes[:branch_name] = GitMetadata.current_branch
        attributes[:git_sha] = GitMetadata.current_sha

        author_name, author_email = git_author_of(migration_path)
        attributes[:author_name] = author_name
        attributes[:author_email] = author_email
      end

      Snapshot.store(**attributes)
    rescue => e
      # Don't break migrations if snapshot capture fails
      warn "[Mighost] Failed to capture snapshot for #{version}: #{e.message}"
    end

    private

    def git_author_of(filepath)
      return [nil, nil] unless GitMetadata.git_available?

      escaped = Shellwords.shellescape(filepath)
      output = `git log --format='%aN\t%aE' --follow -1 -- #{escaped} 2>/dev/null`.strip
      return [nil, nil] if output.empty?

      output.split("\t", 2)
    rescue
      [nil, nil]
    end
  end
end
