# frozen_string_literal: true

RSpec.describe Mighost::Supersession do
  let(:ghost_version) { "20260702110000" }
  let(:newer_version) { "20260706130000" }
  let(:suffix) { "add_utility_belt_to_batcaves" }
  let(:ghost_filename) { "#{ghost_version}_#{suffix}.rb" }
  let(:newer_filename) { "#{newer_version}_#{suffix}.rb" }

  describe ".find_superseder" do
    it "finds an applied on-disk version owning the same name suffix" do
      result = described_class.find_superseder(
        ghost_version,
        filename: ghost_filename,
        applied_versions: [ghost_version, newer_version],
        disk_files: [newer_filename]
      )

      expect(result).to eq(newer_version)
    end

    it "ignores candidates that are not in schema_migrations" do
      result = described_class.find_superseder(
        ghost_version,
        filename: ghost_filename,
        applied_versions: [ghost_version],
        disk_files: [newer_filename]
      )

      expect(result).to be_nil
    end

    it "ignores applied candidates without a file on disk" do
      result = described_class.find_superseder(
        ghost_version,
        filename: ghost_filename,
        applied_versions: [ghost_version, newer_version],
        disk_files: []
      )

      expect(result).to be_nil
    end

    it "ignores versions with a different name suffix" do
      result = described_class.find_superseder(
        ghost_version,
        filename: ghost_filename,
        applied_versions: [ghost_version, newer_version],
        disk_files: ["#{newer_version}_add_something_else.rb"]
      )

      expect(result).to be_nil
    end

    it "returns nil without a recovered filename" do
      result = described_class.find_superseder(
        ghost_version,
        filename: nil,
        applied_versions: [newer_version],
        disk_files: [newer_filename]
      )

      expect(result).to be_nil
    end

    it "picks the newest version when several own the suffix" do
      newest = "20260710000000"
      result = described_class.find_superseder(
        ghost_version,
        filename: ghost_filename,
        applied_versions: [ghost_version, newer_version, newest],
        disk_files: [newer_filename, "#{newest}_#{suffix}.rb"]
      )

      expect(result).to eq(newest)
    end
  end
end
