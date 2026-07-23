# frozen_string_literal: true

# active_support must load before any core_ext cherry-pick (AS 7.1 requirement)
require "active_support"
require "active_support/core_ext/integer/time"

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

    # Hide superseded orphans from detection (off by default: supersession is a
    # name-suffix heuristic, and silently dropping rows could mask schema drift)
    attr_accessor :hide_superseded

    def initialize
      @storage_path = ".mighost.sqlite3"
      @auto_capture = true
      @store_git_metadata = true
      @enabled = true
      @dismiss_old_threshold = 6.months
      @hide_superseded = false
    end

    def enabled?
      @enabled
    end
  end
end
