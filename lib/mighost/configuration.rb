# frozen_string_literal: true

module Mighost
  class Configuration
    # Path to SQLite file (relative to Rails.root)
    attr_accessor :storage_path

    # Auto-capture migrations on db:migrate
    attr_accessor :auto_capture

    # Store git metadata (branch, SHA)
    attr_accessor :store_git_metadata

    # Enabled environments (disabled in production by default)
    attr_accessor :enabled

    # Threshold for suggesting dismissal of old unrecoverable migrations
    attr_accessor :dismiss_old_threshold

    def initialize
      @storage_path = ".mighost.sqlite3"
      @auto_capture = true
      @store_git_metadata = true
      @enabled = true
      @dismiss_old_threshold = 6.months
    end

    def enabled?
      @enabled
    end
  end
end
