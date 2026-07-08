# frozen_string_literal: true

RSpec.describe Mighost::Formatting do
  describe ".parse_version_range" do
    let(:versions) { %w[20240101000000 20240201000000 20240301000000] }

    it "matches a single version" do
      expect(described_class.parse_version_range("20240201000000", versions))
        .to eq(%w[20240201000000])
    end

    it "returns empty for an unknown single version" do
      expect(described_class.parse_version_range("19990101000000", versions)).to eq([])
    end

    it "matches an inclusive range" do
      expect(described_class.parse_version_range("20240101000000..20240201000000", versions))
        .to eq(%w[20240101000000 20240201000000])
    end

    it "matches an open-ended range (from onwards)" do
      expect(described_class.parse_version_range("20240201000000..", versions))
        .to eq(%w[20240201000000 20240301000000])
    end

    it "matches an open-ended range (up to)" do
      expect(described_class.parse_version_range("..20240201000000", versions))
        .to eq(%w[20240101000000 20240201000000])
    end

    it "accepts range bounds that are not exact versions" do
      expect(described_class.parse_version_range("20240115..20240315", versions))
        .to eq(%w[20240201000000 20240301000000])
    end

    it "returns empty when no versions are available" do
      expect(described_class.parse_version_range("20240101000000..", [])).to eq([])
    end
  end

  describe ".format_version" do
    it "formats a migration timestamp as a readable date" do
      expect(described_class.format_version("20240115123456")).to eq("2024-01-15 12:34")
    end

    it "passes through non-timestamp values" do
      expect(described_class.format_version("not-a-version")).to eq("not-a-version")
    end
  end

  describe ".format_name" do
    it "strips the version prefix and extension" do
      expect(described_class.format_name("20240115123456_add_utility_belt.rb"))
        .to eq("add_utility_belt")
    end

    it "handles nil" do
      expect(described_class.format_name(nil)).to eq("(unknown)")
    end
  end

  describe ".truncate" do
    it "leaves short strings alone" do
      expect(described_class.truncate("short", 10)).to eq("short")
    end

    it "truncates long strings with an ellipsis" do
      expect(described_class.truncate("a" * 20, 10)).to eq("#{"a" * 7}...")
    end
  end
end
