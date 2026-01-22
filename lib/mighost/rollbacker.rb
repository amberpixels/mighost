# frozen_string_literal: true

require "tempfile"
require_relative "snapshot"

module Mighost
  class Rollbacker
    attr_reader :version, :snapshot

    def initialize(version)
      @version = version.to_s
      @snapshot = Snapshot.find_by_version(@version)
    end

    def rollback!
      raise SnapshotNotFound, "No snapshot found for version #{version}" unless snapshot

      temp_file = write_temp_migration
      begin
        load_and_execute_down(temp_file)
        remove_from_schema_migrations
        Snapshot.delete_by_version(version)
      ensure
        temp_file.close
        temp_file.unlink
      end
    end

    def can_rollback?
      snapshot.present?
    end

    private

    def write_temp_migration
      temp = Tempfile.new(["migration_#{version}_", ".rb"])
      temp.write(snapshot.content)
      temp.flush
      temp
    end

    def load_and_execute_down(temp_file)
      # Load the migration file
      load temp_file.path

      # Find the migration class
      migration_class = find_migration_class

      raise RollbackFailed, "Could not find migration class in #{snapshot.filename}" unless migration_class

      # Execute down
      migration_instance = migration_class.new
      migration_instance.migrate(:down)
    rescue ActiveRecord::IrreversibleMigration => e
      raise RollbackFailed, "Migration #{version} is irreversible: #{e.message}"
    rescue StandardError => e
      raise RollbackFailed, "Failed to rollback #{version}: #{e.message}"
    end

    def find_migration_class
      # Try to extract class name from content
      class_name = extract_class_name
      return class_name.constantize if class_name && Object.const_defined?(class_name)

      # Fallback: find any newly defined migration class
      find_recent_migration_class
    end

    def extract_class_name
      match = snapshot.content.match(/class\s+(\w+)\s*<\s*ActiveRecord::Migration/)
      match[1] if match
    end

    def find_recent_migration_class
      # Get all constants that are migrations
      ObjectSpace.each_object(Class).find do |klass|
        klass < ActiveRecord::Migration && !klass.name.nil?
      end
    end

    def remove_from_schema_migrations
      ActiveRecord::Base.connection.execute(
        "DELETE FROM schema_migrations WHERE version = '#{version}'"
      )
    end

    class << self
      def rollback_all_orphaned!(force: false)
        orphans = OrphanDetector.detect.select(&:recoverable?)

        return { rolled_back: [], failed: [] } if orphans.empty?

        results = { rolled_back: [], failed: [] }

        orphans.each do |orphan|
          rollback_single(orphan.version, results)
        end

        results
      end

      def rollback_version!(version)
        rollbacker = new(version)
        rollbacker.rollback!
      end

      private

      def rollback_single(version, results)
        rollbacker = new(version)
        rollbacker.rollback!
        results[:rolled_back] << version
      rescue StandardError => e
        results[:failed] << { version: version, error: e.message }
      end
    end
  end
end
