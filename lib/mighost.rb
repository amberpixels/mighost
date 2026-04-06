# frozen_string_literal: true

require_relative "mighost/version"
require_relative "mighost/configuration"
require_relative "mighost/formatting"
require_relative "mighost/plain_ui"
require_relative "mighost/api"

module Mighost
  class Error < StandardError; end
  class SnapshotNotFound < Error; end
  class RollbackFailed < Error; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def enabled?
      configuration.enabled?
    end

    # Pluggable UI adapter. Defaults to PlainUI (no colors, no dependencies).
    # Replace with a custom adapter for rich output (e.g. railbow).
    def ui
      @ui ||= PlainUI.new
    end

    attr_writer :ui
  end

  # Mirrors ActiveRecord::Base.connection with Rails 6.1–8.1 compatibility.
  # Usage: Mighost::Base.connection
  module Base
    def self.connection
      if ActiveRecord::Base.respond_to?(:lease_connection)
        ActiveRecord::Base.lease_connection
      else
        ActiveRecord::Base.connection
      end
    end
  end
end

require_relative "mighost/railtie" if defined?(Rails::Railtie)
