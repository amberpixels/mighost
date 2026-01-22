# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Mighost
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates a Mighost initializer and migration for team storage mode"

      class_option :storage, type: :string, default: "stealth",
                             desc: "Storage mode: 'stealth' (SQLite file, personal) or 'team' (project DB, shared)"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/mighost.rb"
      end

      def create_migration
        return unless options[:storage] == "team"

        migration_template "create_mighost_snapshots.rb.tt",
                           File.join(db_migrate_path, "create_mighost_snapshots.rb")
      end

      def show_instructions
        if options[:storage] == "stealth"
          say "\nMighost configured in stealth mode (local SQLite).", :green
          say "Add '.mighost.sqlite3' to your .gitignore"
          say "Your teammates won't know you're using it."
        else
          say "\nMighost configured in team mode (project database).", :green
          say "Run 'rails db:migrate' to create the mighost_snapshots table."
        end
      end

      private

      def db_migrate_path
        if defined?(Rails) && Rails.application
          Rails.application.config.paths["db/migrate"].to_ary.first
        else
          "db/migrate"
        end
      end

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
