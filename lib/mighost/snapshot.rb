# frozen_string_literal: true

require "time"
require "digest"
require "active_support"
require "active_support/core_ext/time"

module Mighost
  class Snapshot
    attr_accessor :id, :version, :content, :filename, :branch_name, :git_sha, :content_hash, :migrated_at, :source,
      :dismissed, :dismissed_at, :author_name, :author_email, :deleted_in_sha, :deleted_at, :deleted_by

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
        db.execute(<<~SQL)
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
            author_email TEXT,
            deleted_in_sha TEXT,
            deleted_at TEXT,
            deleted_by TEXT
          )
        SQL
        db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_#{table_name}_version ON #{table_name}(version)")
        migrate_columns!
      end

      def find_by_version(version)
        ensure_table_exists!
        row = db.get_first_row(
          "SELECT * FROM #{table_name} WHERE version = ? LIMIT 1",
          [version.to_s]
        )
        return nil unless row

        row_to_snapshot(row)
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
            author_email: git_data[:author_email],
            deleted_in_sha: git_data[:deleted_in_sha],
            deleted_at: git_data[:deleted_at],
            deleted_by: git_data[:deleted_by]
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

      def store(version:, content:, filename:, branch_name: nil, git_sha: nil, source: "file", author_name: nil, author_email: nil,
        deleted_in_sha: nil, deleted_at: nil, deleted_by: nil)
        ensure_table_exists!
        content_hash = Digest::SHA256.hexdigest(content)
        migrated_at = Time.current.iso8601
        deleted_at = deleted_at.iso8601 if deleted_at.respond_to?(:iso8601)

        existing = find_by_version(version)
        if existing
          db.execute(<<~SQL, [content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email, deleted_in_sha, deleted_at, deleted_by, version.to_s])
            UPDATE #{table_name}
            SET content = ?, filename = ?, branch_name = ?, git_sha = ?, content_hash = ?, migrated_at = ?, source = ?,
                author_name = ?, author_email = ?, deleted_in_sha = ?, deleted_at = ?, deleted_by = ?
            WHERE version = ?
          SQL
        else
          db.execute(<<~SQL, [version.to_s, content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email, deleted_in_sha, deleted_at, deleted_by])
            INSERT INTO #{table_name} (version, content, filename, branch_name, git_sha, content_hash, migrated_at, source, author_name, author_email, deleted_in_sha, deleted_at, deleted_by)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
        end

        find_by_version(version)
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
          store(
            version: version,
            content: "",
            filename: "",
            source: nil
          )
        end

        dismissed_at = Time.current.iso8601
        db.execute(
          "UPDATE #{table_name} SET dismissed = ?, dismissed_at = ? WHERE version = ?",
          [1, dismissed_at, version.to_s]
        )

        find_by_version(version)
      end

      # Undismiss a migration (restore visibility)
      def undismiss(version)
        ensure_table_exists!
        existing = find_by_version(version)
        return nil unless existing

        db.execute(
          "UPDATE #{table_name} SET dismissed = ?, dismissed_at = ? WHERE version = ?",
          [0, nil, version.to_s]
        )

        find_by_version(version)
      end

      # Get all dismissed versions
      def dismissed_versions
        ensure_table_exists!
        db.execute(
          "SELECT version FROM #{table_name} WHERE dismissed = 1 AND version != ?",
          [SCAN_METADATA_VERSION]
        ).flatten
      end

      def delete_by_version(version)
        ensure_table_exists!
        db.execute("DELETE FROM #{table_name} WHERE version = ?", [version.to_s])
      end

      def all_snapshots
        ensure_table_exists!
        db.execute(
          "SELECT * FROM #{table_name} WHERE version != ? ORDER BY migrated_at DESC",
          [SCAN_METADATA_VERSION]
        ).map { |row| row_to_snapshot(row) }
      end

      # Lightweight version - only metadata, no content (for status display)
      def all_metadata
        ensure_table_exists!
        cols = %i[version filename branch_name git_sha migrated_at source dismissed author_name author_email deleted_in_sha deleted_at deleted_by]
        db.execute(
          "SELECT version, filename, branch_name, git_sha, migrated_at, source, dismissed, author_name, author_email, deleted_in_sha, deleted_at, deleted_by FROM #{table_name} WHERE version != ?",
          [SCAN_METADATA_VERSION]
        ).map do |row|
          record = new(cols.zip(row).to_h)
          record.dismissed = record.dismissed == 1
          record
        end
      end

      def all_versions
        ensure_table_exists!
        db.execute(
          "SELECT version FROM #{table_name} WHERE version != ?",
          [SCAN_METADATA_VERSION]
        ).flatten
      end

      # Close and forget the database handle. Needed when storage_path changes
      # (the handle is memoized on first access).
      def reset_db!
        @db&.close
        @db = nil
      end

      private

      def db
        @db ||= begin
          require "sqlite3"
          SQLite3::Database.new(resolve_storage_path)
        end
      end

      def migrate_columns!
        columns = db.execute("PRAGMA table_info(#{table_name})").map { |c| c[1] }

        unless columns.include?("source")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN source TEXT DEFAULT 'file'")
        end
        unless columns.include?("dismissed")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN dismissed INTEGER DEFAULT 0")
        end
        unless columns.include?("dismissed_at")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN dismissed_at TEXT")
        end
        unless columns.include?("author_name")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN author_name TEXT")
        end
        unless columns.include?("author_email")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN author_email TEXT")
        end
        unless columns.include?("deleted_in_sha")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN deleted_in_sha TEXT")
        end
        unless columns.include?("deleted_at")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN deleted_at TEXT")
        end
        unless columns.include?("deleted_by")
          db.execute("ALTER TABLE #{table_name} ADD COLUMN deleted_by TEXT")
        end
      end

      SNAPSHOT_COLUMNS = %i[id version content filename branch_name git_sha content_hash migrated_at source dismissed dismissed_at author_name author_email deleted_in_sha deleted_at deleted_by].freeze
      private_constant :SNAPSHOT_COLUMNS

      def row_to_snapshot(row)
        record = new(SNAPSHOT_COLUMNS.zip(row).to_h)
        record.dismissed = record.dismissed == 1
        record
      end

      def resolve_storage_path
        path = Mighost.configuration.storage_path

        if defined?(Rails) && Rails.root
          Rails.root.join(path).to_s
        else
          File.expand_path(path, Dir.pwd)
        end
      end
    end
  end
end
