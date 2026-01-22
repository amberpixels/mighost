# frozen_string_literal: true

require_relative "lib/mighost/version"

Gem::Specification.new do |spec|
  spec.name = "mighost"
  spec.version = Mighost::VERSION
  spec.authors = ["Eugen"]
  spec.email = ["eugene@amberpixels.io"]

  spec.summary = "Rollback Rails migrations even when the migration file is missing"
  spec.description = "Captures migration file contents when they run, enabling rollback " \
                     "even when the original file is not present (e.g., after switching git branches)"
  spec.homepage = "https://github.com/amberpixels/mighost"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 6.1", "< 8.1"
  spec.add_dependency "railties", ">= 6.1", "< 8.1"
  spec.add_dependency "tty-table", "~> 0.12"
  spec.add_dependency "pastel", "~> 0.8"
end
