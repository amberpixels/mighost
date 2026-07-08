# frozen_string_literal: true

require "tmpdir"
require "active_record"

RSpec.describe Mighost::Rollbacker do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  before do
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Migration.verbose = false
    connection.execute("CREATE TABLE schema_migrations (version varchar PRIMARY KEY)")
  end

  let(:version) { "20260702110000" }
  let(:migration_version) { ActiveRecord::Migration.current_version }
  let(:content) do
    <<~RUBY
      class CreateBatmobiles < ActiveRecord::Migration[#{migration_version}]
        def change
          create_table :batmobiles
        end
      end
    RUBY
  end

  def connection
    Mighost::Base.connection
  end

  describe "#rollback!" do
    it "executes down, removes the schema_migrations row, and deletes the snapshot", :aggregate_failures do
      Mighost::Snapshot.store(version: version, content: content, filename: "#{version}_create_batmobiles.rb")
      connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")

      # Simulate the migration having run: load and apply it
      Tempfile.create(["migration_", ".rb"]) do |f|
        f.write(content)
        f.flush
        load f.path
      end
      Object.const_get(:CreateBatmobiles).new.migrate(:up)
      expect(connection.table_exists?(:batmobiles)).to be(true)

      described_class.rollback_version!(version)

      expect(connection.table_exists?(:batmobiles)).to be(false)
      expect(connection.select_values("SELECT version FROM schema_migrations")).to be_empty
      expect(Mighost::Snapshot.find_by_version(version)).to be_nil
    end

    it "raises SnapshotNotFound when nothing can recover the version" do
      expect { described_class.rollback_version!("19990101000000") }
        .to raise_error(Mighost::SnapshotNotFound)
    end

    it "raises RollbackFailed when the content has no migration class" do
      Mighost::Snapshot.store(version: version, content: "puts 'not a migration'", filename: "x.rb")

      expect { described_class.rollback_version!(version) }
        .to raise_error(Mighost::RollbackFailed, /Could not find migration class/)
    end

    it "raises RollbackFailed for irreversible migrations" do
      irreversible = <<~RUBY
        class DoSomethingIrreversible < ActiveRecord::Migration[#{migration_version}]
          def change
            raise ActiveRecord::IrreversibleMigration
          end
        end
      RUBY
      Mighost::Snapshot.store(version: version, content: irreversible, filename: "#{version}_do_something_irreversible.rb")

      expect { described_class.rollback_version!(version) }
        .to raise_error(Mighost::RollbackFailed)
    end
  end
end
