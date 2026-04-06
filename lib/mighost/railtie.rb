# frozen_string_literal: true

require "rails/railtie"

module Mighost
  class Railtie < Rails::Railtie
    railtie_name :mighost

    initializer "mighost.configure" do
      Mighost.configuration.enabled = !Rails.env.production?
    end

    initializer "mighost.setup_migrator_extension" do
      ActiveSupport.on_load(:active_record) do
        require_relative "migrator_extension"
      end
    end

    rake_tasks do
      load File.expand_path("tasks.rake", __dir__)
    end

    generators do
      require_relative "../generators/mighost/install_generator"
    end
  end
end
