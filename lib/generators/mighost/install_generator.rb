# frozen_string_literal: true

require "rails/generators"

module Mighost
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a Mighost initializer"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/mighost.rb"
      end

      def show_instructions
        say "\nMighost configured (local SQLite storage).", :green
        say "Add '.mighost.sqlite3' to your .gitignore"
      end
    end
  end
end
