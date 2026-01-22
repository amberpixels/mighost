# frozen_string_literal: true

require "active_record"

module Mighost
  class Snapshot
    attr_accessor :id, :version, :content, :filename, :branch_name, :git_sha, :content_hash, :migrated_at

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

      def store(version:, content:, filename:, branch_name: nil, git_sha: nil)
        ensure_table_exists!
        if Mighost.configuration.stealth_mode?
          stealth_store(version: version, content: content, filename: filename,
                        branch_name: branch_name, git_sha: git_sha)
        else
          ar_store(version: version, content: content, filename: filename,
                   branch_name: branch_name, git_sha: git_sha)
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
            migrated_at TEXT NOT NULL
          )
        SQL
        stealth_db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_#{table_name}_version ON #{table_name}(version)")
      end

      def stealth_find_by_version(version)
        row = stealth_db.get_first_row(
          "SELECT * FROM #{table_name} WHERE version = ? LIMIT 1",
          [version.to_s]
        )
        return nil unless row

        cols = %i[id version content filename branch_name git_sha content_hash migrated_at]
        new(cols.zip(row).to_h)
      end

      def stealth_store(version:, content:, filename:, branch_name:, git_sha:)
        content_hash = Digest::SHA256.hexdigest(content)
        migrated_at = Time.current.iso8601

        existing = stealth_find_by_version(version)
        if existing
          stealth_db.execute(<<~SQL, [content, filename, branch_name, git_sha, content_hash, migrated_at, version.to_s])
            UPDATE #{table_name}
            SET content = ?, filename = ?, branch_name = ?, git_sha = ?, content_hash = ?, migrated_at = ?
            WHERE version = ?
          SQL
        else
          stealth_db.execute(<<~SQL, [version.to_s, content, filename, branch_name, git_sha, content_hash, migrated_at])
            INSERT INTO #{table_name} (version, content, filename, branch_name, git_sha, content_hash, migrated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
        end

        stealth_find_by_version(version)
      end

      def stealth_delete_by_version(version)
        stealth_db.execute("DELETE FROM #{table_name} WHERE version = ?", [version.to_s])
      end

      def stealth_all_snapshots
        cols = %i[id version content filename branch_name git_sha content_hash migrated_at]
        stealth_db.execute("SELECT * FROM #{table_name} ORDER BY migrated_at DESC").map do |row|
          new(cols.zip(row).to_h)
        end
      end

      def stealth_all_versions
        stealth_db.execute("SELECT version FROM #{table_name}").flatten
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
        ActiveRecord::Base.connection
      end

      def ensure_ar_table_exists!
        conn = ar_connection
        return if conn.table_exists?(table_name)

        conn.create_table table_name do |t|
          t.string :version, null: false
          t.text :content, null: false
          t.string :filename, null: false
          t.string :branch_name
          t.string :git_sha
          t.string :content_hash
          t.datetime :migrated_at, null: false

          t.index :version, unique: true
        end
      end

      def ar_find_by_version(version)
        conn = ar_connection
        result = conn.select_one(
          "SELECT * FROM #{table_name} WHERE version = #{conn.quote(version.to_s)} LIMIT 1"
        )
        result ? new(symbolize_keys(result)) : nil
      end

      def ar_store(version:, content:, filename:, branch_name:, git_sha:)
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
                migrated_at = #{conn.quote(migrated_at.iso8601)}
            WHERE version = #{conn.quote(version.to_s)}
          SQL
        else
          conn.execute(<<~SQL)
            INSERT INTO #{table_name} (version, content, filename, branch_name, git_sha, content_hash, migrated_at)
            VALUES (
              #{conn.quote(version.to_s)},
              #{conn.quote(content)},
              #{conn.quote(filename)},
              #{conn.quote(branch_name)},
              #{conn.quote(git_sha)},
              #{conn.quote(content_hash)},
              #{conn.quote(migrated_at.iso8601)}
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
        results = conn.select_all("SELECT * FROM #{table_name} ORDER BY migrated_at DESC")
        results.map { |row| new(symbolize_keys(row)) }
      end

      def ar_all_versions
        conn = ar_connection
        conn.select_values("SELECT version FROM #{table_name}")
      end

      def symbolize_keys(hash)
        hash.transform_keys(&:to_sym)
      end
    end
  end
end
