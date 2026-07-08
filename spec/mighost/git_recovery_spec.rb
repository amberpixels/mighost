# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Mighost::GitRecovery do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  before do
    # git_available? memoizes per-process; reset so each temp repo is re-checked
    if described_class.instance_variable_defined?(:@git_available)
      described_class.remove_instance_variable(:@git_available)
    end
    init_repo
  end

  let(:version) { "20260702110000" }
  let(:filename) { "#{version}_add_utility_belt_to_batcaves.rb" }
  let(:content) { "class AddUtilityBeltToBatcaves < ActiveRecord::Migration[8.1]\nend\n" }

  def git(*args)
    system("git", *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def init_repo
    git "init", "-q"
    git "config", "user.name", "Bruce Wayne"
    git "config", "user.email", "batman@example.com"
    FileUtils.mkdir_p("db/migrate")
  end

  def commit_migration
    File.write("db/migrate/#{filename}", content)
    git "add", "db/migrate/#{filename}"
    git "commit", "-q", "-m", "add migration"
  end

  describe ".find_migration" do
    it "recovers a migration still present in history", :aggregate_failures do
      commit_migration

      result = described_class.find_migration(version)

      expect(result).not_to be_nil
      expect(result[:content]).to eq(content)
      expect(result[:filename]).to eq(filename)
      expect(result[:author_name]).to eq("Bruce Wayne")
      expect(result[:author_email]).to eq("batman@example.com")
    end

    it "recovers a migration whose last touch in history is a deletion", :aggregate_failures do
      commit_migration
      git "rm", "-q", "db/migrate/#{filename}"
      git "commit", "-q", "-m", "re-timestamp migration"

      result = described_class.find_migration(version)

      expect(result).not_to be_nil
      expect(result[:content]).to eq(content)
      expect(result[:filename]).to eq(filename)
    end

    it "returns nil for a version that never existed" do
      commit_migration

      expect(described_class.find_migration("19990101000000")).to be_nil
    end
  end
end
