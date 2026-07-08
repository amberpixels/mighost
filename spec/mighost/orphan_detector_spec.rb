# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "active_record"

RSpec.describe Mighost::OrphanDetector do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  before do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = Mighost::Base.connection
    connection.execute("CREATE TABLE schema_migrations (version varchar PRIMARY KEY)")
    FileUtils.mkdir_p("db/migrate")
  end

  let(:present_version) { "20260701000000" }
  let(:ghost_version) { "20260702000000" }

  def mark_migrated(version)
    Mighost::Base.connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")
  end

  describe ".detect" do
    it "reports versions in schema_migrations that have no file on disk", :aggregate_failures do
      mark_migrated(present_version)
      mark_migrated(ghost_version)
      File.write("db/migrate/#{present_version}_add_grappling_hook.rb", "# present")

      orphans = described_class.detect

      expect(orphans.map(&:version)).to eq([ghost_version])
      expect(orphans.first).not_to be_recoverable
    end

    it "enriches orphans with snapshot data when available", :aggregate_failures do
      mark_migrated(ghost_version)
      Mighost::Snapshot.store(
        version: ghost_version,
        content: "class AddCape < ActiveRecord::Migration[8.1]\nend\n",
        filename: "#{ghost_version}_add_cape.rb",
        branch_name: "feature/cape",
        source: "git"
      )

      orphan = described_class.detect.first

      expect(orphan.filename).to eq("#{ghost_version}_add_cape.rb")
      expect(orphan.branch_name).to eq("feature/cape")
      expect(orphan).to be_recoverable
      expect(orphan.recovery_source).to eq(:branch)
    end

    it "hides dismissed orphans unless asked", :aggregate_failures do
      mark_migrated(ghost_version)
      Mighost::Snapshot.dismiss(ghost_version)

      expect(described_class.detect).to be_empty

      shown = described_class.detect(include_dismissed: true)
      expect(shown.map(&:version)).to eq([ghost_version])
      expect(shown.first.dismissed).to be(true)
    end

    it "returns nothing when every migrated version has a file" do
      mark_migrated(present_version)
      File.write("db/migrate/#{present_version}_add_grappling_hook.rb", "# present")

      expect(described_class.detect).to be_empty
    end
  end

  describe Mighost::OrphanDetector::OrphanedMigration do
    it "parses created_at from the version timestamp" do
      orphan = described_class.new(version: "20240115123456")

      expect(orphan.created_at).to eq(Time.new(2024, 1, 15, 12, 34, 56))
    end

    it "suggests dismissal only for old, unrecoverable orphans", :aggregate_failures do
      old_version = (Time.now.year - 2).to_s + "0101000000"

      old_unrecoverable = described_class.new(version: old_version)
      expect(old_unrecoverable.suggested_for_dismiss?).to be(true)

      old_recoverable = described_class.new(version: old_version, source: "git")
      expect(old_recoverable.suggested_for_dismiss?).to be(false)

      fresh = described_class.new(version: Time.now.strftime("%Y%m%d%H%M%S"))
      expect(fresh.suggested_for_dismiss?).to be(false)
    end
  end
end
