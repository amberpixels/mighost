# frozen_string_literal: true

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
      end

      Snapshot.store(**attributes)
    rescue StandardError => e
      # Don't break migrations if snapshot capture fails
      warn "[Mighost] Failed to capture snapshot for #{version}: #{e.message}"
    end
  end
end
