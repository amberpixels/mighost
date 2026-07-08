# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "standard", "~> 1.44"
  gem "sqlite3"
  # RAILS_VERSION lets CI test against multiple Rails releases
  gem "rails", ENV.fetch("RAILS_VERSION", "~> 8.1")
end
