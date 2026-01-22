# frozen_string_literal: true

module Mighost
  class Configuration
    # Storage mode: :stealth (SQLite file) or :team (project's DB)
    attr_accessor :storage

    # Path to SQLite file (when storage: :stealth)
    attr_accessor :stealth_storage_path

    # Table name for snapshots (when storage: :team)
    attr_accessor :table_name

    # Auto-capture migrations on db:migrate
    attr_accessor :auto_capture

    # Store git metadata (branch, SHA)
    attr_accessor :store_git_metadata

    # Enabled environments (disabled in production by default)
    attr_accessor :enabled

    def initialize
      @storage = :stealth
      @stealth_storage_path = ".mighost.sqlite3"
      @table_name = :mighost_snapshots
      @auto_capture = true
      @store_git_metadata = true
      @enabled = true
    end

    def enabled?
      @enabled
    end

    def stealth_mode?
      @storage == :stealth
    end

    def team_mode?
      @storage == :team
    end
  end
end
