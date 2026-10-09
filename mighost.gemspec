# frozen_string_literal: true

require_relative "lib/mighost/version"

Gem::Specification.new do |spec|
  spec.name = "mighost"
  spec.version = Mighost::VERSION
  spec.authors = ["Eugene M"]
  spec.email = ["eugene@amberpixels.io"]

  spec.summary = "Rollback Rails migrations even when the migration file is missing"
  spec.description = "Captures migration file contents when they run, enabling rollback " \
                     "even when the original file is not present (e.g., after switching git branches)"
  spec.homepage = "https://github.com/amberpixels/mighost"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.{rb,rake,tt}"] + %w[LICENSE README.md CHANGELOG.md]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 6.1", "< 8.2"
  spec.add_dependency "railties", ">= 6.1", "< 8.2"
  spec.add_dependency "sqlite3", ">= 1.4"
end
