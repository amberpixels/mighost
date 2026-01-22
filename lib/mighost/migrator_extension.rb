# frozen_string_literal: true

require_relative "capturer"

module Mighost
  module MigratorExtension
    def record_version_state_after_migrating(version)
      super

      # Only capture on UP migrations, not DOWN
      return unless up?

      migration = migrations.find { |m| m.version == version }
      return unless migration

      Capturer.new(version, migration.filename).capture
    end

    private

    def up?
      @direction == :up
    end
  end
end

# Prepend to ActiveRecord::Migrator
ActiveSupport.on_load(:active_record) do
  ActiveRecord::Migrator.prepend(Mighost::MigratorExtension)
end
