# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Mighost::Snapshot do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  let(:version) { "20260702110000" }
  let(:content) { "class AddUtilityBeltToBatcaves < ActiveRecord::Migration[8.1]\nend\n" }

  def store_snapshot(v = version, **overrides)
    described_class.store(
      version: v,
      content: content,
      filename: "#{v}_add_utility_belt_to_batcaves.rb",
      branch_name: "feature/utility-belt",
      git_sha: "abc123def456",
      author_name: "Bruce Wayne",
      author_email: "batman@example.com",
      **overrides
    )
  end

  describe ".store / .find_by_version" do
    it "round-trips a snapshot", :aggregate_failures do
      store_snapshot

      found = described_class.find_by_version(version)
      expect(found).not_to be_nil
      expect(found.content).to eq(content)
      expect(found.branch_name).to eq("feature/utility-belt")
      expect(found.author_name).to eq("Bruce Wayne")
      expect(found.source).to eq("file")
      expect(found.dismissed).to be(false)
    end

    it "returns nil for unknown versions" do
      expect(described_class.find_by_version("19990101000000")).to be_nil
    end

    it "updates the existing row on re-store instead of duplicating", :aggregate_failures do
      store_snapshot
      store_snapshot(version, branch_name: "main")

      expect(described_class.all_snapshots.count).to eq(1)
      expect(described_class.find_by_version(version).branch_name).to eq("main")
    end
  end

  describe ".dismiss / .undismiss" do
    it "hides and restores a version", :aggregate_failures do
      store_snapshot
      described_class.dismiss(version)
      expect(described_class.dismissed_versions).to eq([version])

      described_class.undismiss(version)
      expect(described_class.dismissed_versions).to be_empty
    end

    it "creates a placeholder row when dismissing an unknown version" do
      described_class.dismiss(version)

      expect(described_class.dismissed_versions).to eq([version])
    end
  end

  describe ".delete_by_version" do
    it "removes the row" do
      store_snapshot
      described_class.delete_by_version(version)

      expect(described_class.find_by_version(version)).to be_nil
    end
  end

  describe ".scan_metadata" do
    it "stores and retrieves scan context without leaking into snapshot lists", :aggregate_failures do
      described_class.store_scan_metadata(branch: "main", sha: "abc123")

      expect(described_class.scan_metadata).to eq({branch: "main", sha: "abc123"})
      expect(described_class.all_snapshots).to be_empty
      expect(described_class.all_versions).to be_empty
    end
  end

  describe ".all_metadata" do
    it "returns rows without loading content", :aggregate_failures do
      store_snapshot

      record = described_class.all_metadata.first
      expect(record.version).to eq(version)
      expect(record.filename).to eq("#{version}_add_utility_belt_to_batcaves.rb")
      expect(record.content).to be_nil
    end
  end

  it "respects a custom storage_path" do
    Mighost.configure { |c| c.storage_path = "custom/ghosts.sqlite3" }
    FileUtils.mkdir_p("custom")

    store_snapshot

    expect(File).to exist("custom/ghosts.sqlite3")
  end
end
