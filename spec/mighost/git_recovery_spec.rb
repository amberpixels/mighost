# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Mighost::GitRecovery do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  before { init_repo }

  let(:version) { "20260702110000" }
  let(:filename) { "#{version}_add_utility_belt_to_batcaves.rb" }
  let(:content) { "class AddUtilityBeltToBatcaves < ActiveRecord::Migration[8.1]\nend\n" }

  def git(*args)
    system("git", *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def init_repo
    git "init", "-q", "-b", "main"
    git "config", "user.name", "Bruce Wayne"
    git "config", "user.email", "batman@example.com"
    FileUtils.mkdir_p("db/migrate")
  end

  def commit_migration
    File.write("db/migrate/#{filename}", content)
    git "add", "db/migrate/#{filename}"
    git "commit", "-q", "-m", "add migration"
  end

  def delete_migration
    git "rm", "-q", "db/migrate/#{filename}"
    git "commit", "-q", "-m", "re-timestamp migration"
  end

  def head_sha
    `git rev-parse HEAD`.strip
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
      delete_migration

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

  describe "branch attribution" do
    it "reports no branch but deletion metadata when the file is gone from every tip", :aggregate_failures do
      commit_migration
      delete_migration
      deleting_sha = head_sha
      git "branch", "feature/cut-after-deletion"

      result = described_class.find_migration(version)

      expect(result[:branch]).to be_nil
      expect(result[:deleted_in_sha]).to eq(deleting_sha[0, 12])
      expect(result[:deleted_at]).not_to be_nil
      expect(result[:deleted_by]).to eq("Bruce Wayne")
    end

    it "reports the branch that still has the file when it was deleted elsewhere", :aggregate_failures do
      commit_migration
      git "branch", "feature/x"
      delete_migration

      result = described_class.find_migration(version)

      expect(result[:branch]).to eq("feature/x")
      expect(result[:deleted_in_sha]).to be_nil
    end

    it "prefers the current branch when several tips have the file" do
      commit_migration
      git "checkout", "-q", "-b", "feature/current"

      expect(described_class.find_migration(version)[:branch]).to eq("feature/current")
    end

    it "reports a remote-only branch with its origin/ prefix intact" do
      commit_migration
      git "update-ref", "refs/remotes/origin/foo", head_sha
      delete_migration

      expect(described_class.find_migration(version)[:branch]).to eq("origin/foo")
    end

    it "prefers the default branch over alphabetically-earlier branches" do
      commit_migration
      10.times { |i| git "branch", "A-#{i}/earlier" }
      git "checkout", "-q", "-b", "work"
      delete_migration

      expect(described_class.find_migration(version)[:branch]).to eq("main")
    end
  end
end
