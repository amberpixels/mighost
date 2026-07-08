# frozen_string_literal: true

require "tempfile"
require "active_support"
require "active_support/core_ext/object/blank"
require_relative "snapshot"
require_relative "git_recovery"
require_relative "worktree_recovery"

module Mighost
  class Rollbacker
    attr_reader :version, :content, :filename, :recovery_source

    def initialize(version)
      @version = version.to_s
      load_recovery_data
    end

    def rollback!
      raise SnapshotNotFound, "No snapshot or git recovery found for version #{version}" unless can_rollback?

      temp_file = write_temp_migration
      begin
        load_and_execute_down(temp_file)
        remove_from_schema_migrations
        Snapshot.delete_by_version(version) if recovery_source == :snapshot
      ensure
        temp_file.close
        temp_file.unlink
      end
    end

    def can_rollback?
      content.present?
    end

    private

    def load_recovery_data
      # Try snapshot first
      snapshot = Snapshot.find_by_version(version)
      if snapshot
        @content = snapshot.content
        @filename = snapshot.filename
        @recovery_source = :snapshot
        return
      end

      # Fallback to git recovery
      git_data = GitRecovery.find_migration(version)
      if git_data
        @content = git_data[:content]
        @filename = git_data[:filename]
        @recovery_source = :branch
        return
      end

      # Fallback to worktree recovery (uncommitted files in other worktrees)
      wt_data = WorktreeRecovery.find_migration(version)
      if wt_data
        @content = wt_data[:content]
        @filename = wt_data[:filename]
        @recovery_source = :worktree
      end
    end

    def write_temp_migration
      temp = Tempfile.new(["migration_#{version}_", ".rb"])
      temp.write(content)
      temp.flush
      temp
    end

    def load_and_execute_down(temp_file)
      class_name = extract_class_name
      unless class_name
        raise RollbackFailed, "Could not find migration class in #{filename}"
      end

      load temp_file.path

      unless Object.const_defined?(class_name)
        raise RollbackFailed, "Loading #{filename} did not define #{class_name}"
      end

      Object.const_get(class_name).new.migrate(:down)
    rescue ActiveRecord::IrreversibleMigration => e
      raise RollbackFailed, "Migration #{version} is irreversible: #{e.message}"
    rescue RollbackFailed
      raise
    rescue => e
      raise RollbackFailed, "Failed to rollback #{version}: #{e.message}"
    end

    def extract_class_name
      match = content.match(/class\s+(\w+)\s*<\s*ActiveRecord::Migration(\[\d+\.\d+\])?/)
      match[1] if match
    end

    def remove_from_schema_migrations
      conn = Mighost::Base.connection
      conn.execute(
        "DELETE FROM schema_migrations WHERE version = #{conn.quote(version)}"
      )
    end

    class << self
      def rollback_version!(version)
        new(version).rollback!
      end
    end
  end
end
