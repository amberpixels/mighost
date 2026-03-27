# frozen_string_literal: true

require "active_record"

module Mighost
  class Snapshot
    attr_accessor :id, :version, :content, :filename, :branch_name, :git_sha, :content_hash, :migrated_at, :source,
      :dismissed, :dismissed_at, :author_name, :author_email

    # Special version used to store scan metadata
    SCAN_METADATA_VERSION = "__scan_metadata__"

    def initialize(attrs = {})
      attrs.each { |k, v| send("#{k}=", v) if respond_to?("#{k}=") }
    end

    class << self
      def table_name
        "mighost_snapshots"
      end

      def ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          ensure_stealth_table_exists!
        else
          ensure_ar_table_exists!
        end
      end

      def find_by_version(version)
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_find_by_version(version)
        else
          ar_find_by_version(version)
        end
      end

      def find_or_recover(version)
        existing = find_by_version(version)
        return existing if existing

        require_relative "git_recovery"
        git_data = GitRecovery.find_migration(version)
        if git_data
          return store(
            version: version,
            content: git_data[:content],
            filename: git_data[:filename],
            branch_name: git_data[:branch],
            git_sha: git_data[:sha],
            source: "git",
            author_name: git_data[:author_name],
            author_email: git_data[:author_email]
          )
        end

        require_relative "worktree_recovery"
        wt_data = WorktreeRecovery.find_migration(version)
        return nil unless wt_data

        store(
          version: version,
          content: wt_data[:content],
          filename: wt_data[:filename],
          branch_name: wt_data[:branch],
          source: "worktree",
          author_name: wt_data[:author_name],
          author_email: wt_data[:author_email]
        )
      end

      def store(version:, content:, filename:, branch_name: nil, git_sha: nil, source: "file", author_name: nil, author_email: nil)
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_store(version: version, content: content, filename: filename,
            branch_name: branch_name, git_sha: git_sha, source: source,
            author_name: author_name, author_email: author_email)
        else
          ar_store(version: version, content: content, filename: filename,
            branch_name: branch_name, git_sha: git_sha, source: source,
            author_name: author_name, author_email: author_email)
        end
      end

      # Store scan context metadata (branch and SHA when scan was performed)
      def store_scan_metadata(branch:, sha:)
        ensure_table_exists!
        store(
          version: SCAN_METADATA_VERSION,
          content: "",
          filename: "",
          branch_name: branch,
          git_sha: sha,
          source: "metadata"
        )
      end

      # Retrieve scan context metadata
      def scan_metadata
        ensure_table_exists!
        record = find_by_version(SCAN_METADATA_VERSION)
        return nil unless record

        {branch: record.branch_name, sha: record.git_sha}
      end

      # Dismiss a migration (mark as hidden)
      def dismiss(version)
        ensure_table_exists!
        existing = find_by_version(version)

        unless existing
          # Create new record for unknown orphan
          store(
            version: version,
            content: "",
            filename: "",
            source: nil
          )
        end

        if Mighost.configuration.stealth_mode?
          stealth_update_dismissed(version, true)
        else
          ar_update_dismissed(version, true)
        end

        find_by_version(version)
      end

      # Undismiss a migration (restore visibility)
      def undismiss(version)
        ensure_table_exists!
        existing = find_by_version(version)
        return nil unless existing

        if Mighost.configuration.stealth_mode?
          stealth_update_dismissed(version, false)
        else
          ar_update_dismissed(version, false)
        end

        find_by_version(version)
      end

      # Get all dismissed versions
      def dismissed_versions
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_dismissed_versions
        else
          ar_dismissed_versions
        end
      end

      def delete_by_version(version)
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_delete_by_version(version)
        else
          ar_delete_by_version(version)
        end
      end

      def all_snapshots
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_all_snapshots
        else
          ar_all_snapshots
        end
      end

      # Lightweight version - only metadata, no content (for status display)
      def all_metadata
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_all_metadata
        else
          ar_all_metadata
        end
      end

      def all_versions
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_all_versions
        else
          ar_all_versions
        end
      end

      private

      # ========== Stealth Mode (SQLite3 direct) ==========

      def stealth_db
        @stealth_db ||= begin
          require "sqlite3"
          SQLite3::Database.new(resolve_stealth_path)
        end
      end

      def ensure_stealth_table_exists!
        stealth_db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{table_name} (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            version TEXT NOT NULL UNIQUE,
            content TEXT NOT NULL,
            filename TEXT NOT NULL,
            branch_name TEXT,
            git_sha TEXT,
            content_hash TEXT,
            migrated_at TEXT NOT NULL,
            source TEXT DEFAULT 'file',
            dismissed INTEGER DEFAULT 0,
            dismissed_at TEXT,
            author_name TEXT,
            author_email TEXT
          )
        SQL
        stealth_db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_#{table_name}_version ON #{table_name}(version)")
        stealth_migrate_columns!
      end

      def stealth_migrate_columns!
        columns = stealth_db.execute("PRAGMA table_info(#{table_name})").map { |c| c[1] }

        unless columns.include?("source")
          stealth_db.execute("ALTER TABLE #{table_name} ADD COLUMN source TEXT DEFAULT 'file'")
        end
        unless columns.include?("dismissed")
          stealth_db.execute("ALTER TABLE #{table_name} ADD COLUMN dismissed INTEGER DEFAULT 0")
        end
        unless columns.include?("dismissed_at")
          stealth_db.execute("ALTER TABLE #{table_name} ADD COLUMN dismissed_at TEXT")
        end
        unless columns.include?("author_name")
          stealth_db.execute("ALTER TABLE #{table_name} ADD COLUMN author_name TEXT")
        end
        unless columns.include?("author_email")
          stealth_db.execute("ALTER TABLE #{table_name} ADD COLUMN author_email TEXT")
        end
      end

      def stealth_find_by_version(version)
        row = stealth_db.get_first_row(
          "SELECT * FROM #{table_name} WHERE version = ? LIMIT 1",
          [version.to_s]
        )
        return nil unless row

        cols = %i[id version content filename branch_name git_sha content_hash migrated_at source dismissed dismissed_at author_name author_email]
        record = new(cols.zip(row).to_h)
        record.dismissed = record.dismissed == 1 # SQLite stores as integer
        record
      end

      def stealth_update_dismissed(version, dismissed)
        dismissed_at = dismissed ? Time.current.iso8601 : nil
        stealth_db.execute(
          "UPDATE #{table_name} SET dismissed = ?, dismissed_at = ? WHERE version = ?",
          [dismissed ? 1 : 0, dismissed_at, version.to_s]
        )
      end

      def stealth_dismissed_versions
        stealth_db.execute(
          "SELECT version FROM #{table_name} WHERE dismissed = 1 AND version != ?",
          [SCAN_METADATA_VERSION]
        ).flatten
      end

      def stealth_store(version:, content:, filename:, branch_name:, git_sha:, source:, author_name:, author_email:)
        content_hash = Digest::SHA256.hexdigest(content)
        migrated_at = Time.current.iso8601

        existing = stealth_find_by_version(version)
        if existing
          stealth_db.execute(<<~SQL, [content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email, version.to_s])
            UPDATE #{table_name}
            SET content = ?, filename = ?, branch_name = ?, git_sha = ?, content_hash = ?, migrated_at = ?, source = ?,
                author_name = ?, author_email = ?
            WHERE version = ?
          SQL
        else
          stealth_db.execute(<<~SQL, [version.to_s, content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email])
            INSERT INTO #{table_name} (version, content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
        end

        stealth_find_by_version(version)
      end

      def stealth_delete_by_version(version)
        stealth_db.execute("DELETE FROM #{table_name} WHERE version = ?", [version.to_s])
      end

      def stealth_all_snapshots
        cols = %i[id version content filename branch_name git_sha content_hash migrated_at source dismissed dismissed_at author_name author_email]
        stealth_db.execute(
          "SELECT * FROM #{table_name} WHERE version != ? ORDER BY migrated_at DESC",
          [SCAN_METADATA_VERSION]
        ).map do |row|
          record = new(cols.zip(row).to_h)
          record.dismissed = record.dismissed == 1
          record
        end
      end

      def stealth_all_metadata
        cols = %i[version filename branch_name git_sha migrated_at source dismissed author_name author_email]
        stealth_db.execute(
          "SELECT version, filename, branch_name, git_sha, migrated_at, source, dismissed, author_name, author_email FROM #{table_name} WHERE version != ?",
          [SCAN_METADATA_VERSION]
        ).map do |row|
          record = new(cols.zip(row).to_h)
          record.dismissed = record.dismissed == 1
          record
        end
      end

      def stealth_all_versions
        stealth_db.execute(
          "SELECT version FROM #{table_name} WHERE version != ?",
          [SCAN_METADATA_VERSION]
        ).flatten
      end

      def resolve_stealth_path
        path = Mighost.configuration.stealth_storage_path

        if defined?(Rails) && Rails.root
          Rails.root.join(path).to_s
        else
          File.expand_path(path, Dir.pwd)
        end
      end

      # ========== Team Mode (ActiveRecord) ==========

      def ar_connection
        Mighost::Base.connection
      end

      def ensure_ar_table_exists!
        conn = ar_connection
        if conn.table_exists?(table_name)
          ar_migrate_columns!
          return
        end

        conn.create_table table_name do |t|
          t.string :version, null: false
          t.text :content, null: false
          t.string :filename, null: false
          t.string :branch_name
          t.string :git_sha
          t.string :content_hash
          t.datetime :migrated_at, null: false
          t.string :source, default: "file"
          t.boolean :dismissed, default: false
          t.datetime :dismissed_at
          t.string :author_name
          t.string :author_email

          t.index :version, unique: true
        end
      end

      def ar_migrate_columns!
        conn = ar_connection
        unless conn.column_exists?(table_name, :source)
          conn.add_column table_name, :source, :string, default: "file"
        end
        unless conn.column_exists?(table_name, :dismissed)
          conn.add_column table_name, :dismissed, :boolean, default: false
        end
        unless conn.column_exists?(table_name, :dismissed_at)
          conn.add_column table_name, :dismissed_at, :datetime
        end
        unless conn.column_exists?(table_name, :author_name)
          conn.add_column table_name, :author_name, :string
        end
        unless conn.column_exists?(table_name, :author_email)
          conn.add_column table_name, :author_email, :string
        end
      end

      def ar_update_dismissed(version, dismissed)
        conn = ar_connection
        dismissed_at = dismissed ? Time.current : nil
        conn.execute(<<~SQL)
          UPDATE #{table_name}
          SET dismissed = #{conn.quote(dismissed)},
              dismissed_at = #{conn.quote(dismissed_at&.iso8601)}
          WHERE version = #{conn.quote(version.to_s)}
        SQL
      end

      def ar_dismissed_versions
        conn = ar_connection
        conn.select_values(
          "SELECT version FROM #{table_name} WHERE dismissed = #{conn.quote(true)} AND version != #{conn.quote(SCAN_METADATA_VERSION)}"
        )
      end

      def ar_find_by_version(version)
        conn = ar_connection
        result = conn.select_one(
          "SELECT * FROM #{table_name} WHERE version = #{conn.quote(version.to_s)} LIMIT 1"
        )
        result ? new(symbolize_keys(result)) : nil
      end

      def ar_store(version:, content:, filename:, branch_name:, git_sha:, source:, author_name:, author_email:)
        conn = ar_connection
        content_hash = Digest::SHA256.hexdigest(content)
        migrated_at = Time.current

        existing = ar_find_by_version(version)
        if existing
          conn.execute(<<~SQL)
            UPDATE #{table_name}
            SET content = #{conn.quote(content)},
                filename = #{conn.quote(filename)},
                branch_name = #{conn.quote(branch_name)},
                git_sha = #{conn.quote(git_sha)},
                content_hash = #{conn.quote(content_hash)},
                migrated_at = #{conn.quote(migrated_at.iso8601)},
                source = #{conn.quote(source)},
                author_name = #{conn.quote(author_name)},
                author_email = #{conn.quote(author_email)}
            WHERE version = #{conn.quote(version.to_s)}
          SQL
        else
          conn.execute(<<~SQL)
            INSERT INTO #{table_name} (version, content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email)
            VALUES (
              #{conn.quote(version.to_s)},
              #{conn.quote(content)},
              #{conn.quote(filename)},
              #{conn.quote(branch_name)},
              #{conn.quote(git_sha)},
              #{conn.quote(content_hash)},
              #{conn.quote(migrated_at.iso8601)},
              #{conn.quote(source)},
              #{conn.quote(author_name)},
              #{conn.quote(author_email)}
            )
          SQL
        end

        ar_find_by_version(version)
      end

      def ar_delete_by_version(version)
        conn = ar_connection
        conn.execute("DELETE FROM #{table_name} WHERE version = #{conn.quote(version.to_s)}")
      end

      def ar_all_snapshots
        conn = ar_connection
        results = conn.select_all(
          "SELECT * FROM #{table_name} WHERE version != #{conn.quote(SCAN_METADATA_VERSION)} ORDER BY migrated_at DESC"
        )
        results.map { |row| new(symbolize_keys(row)) }
      end

      def ar_all_metadata
        conn = ar_connection
        cols = "version, filename, branch_name, git_sha, migrated_at, source, dismissed, author_name, author_email"
        results = conn.select_all(
          "SELECT #{cols} FROM #{table_name} WHERE version != #{conn.quote(SCAN_METADATA_VERSION)}"
        )
        results.map { |row| new(symbolize_keys(row)) }
      end

      def ar_all_versions
        conn = ar_connection
        conn.select_values(
          "SELECT version FROM #{table_name} WHERE version != #{conn.quote(SCAN_METADATA_VERSION)}"
        )
      end

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
