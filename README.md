# Mighost

Rollback Rails migrations even when the migration file is missing.

## The Problem

When working with Rails migrations across git branches:

1. You run migrations on a feature branch
2. Switch back to `main`
3. Run `db:migrate` - Rails dumps schema including changes from the other branch
4. You can't rollback because the migration files don't exist in current branch

**Usual workaround**: Switch to the other branch, rollback, switch back. Tedious.

## The Solution

Mighost automatically captures migration file contents when they run, enabling rollback even when the original file is not present.

## Installation

Add to your Gemfile:

```ruby
gem 'mighost', group: [:development, :test]
```

Then run:

```bash
bundle install
rails generate mighost:install
```

## Storage Modes

### Stealth Mode (Default)

Stores snapshots in a local SQLite file (`.mighost.sqlite3`). Perfect for personal use - no schema changes, teammates don't need to know.

```bash
rails generate mighost:install
# or explicitly:
rails generate mighost:install --storage=stealth
```

Add to `.gitignore`:
```
.mighost.sqlite3
```

### Team Mode

Stores snapshots in your project's database. Visible to everyone, requires a migration.

```bash
rails generate mighost:install --storage=team
rails db:migrate
```

## Usage

### Check for orphaned migrations

```bash
rails mighost:status
```

Output:
```
Orphaned Migrations (2 total, 2 recoverable):

Version          Filename                                 Branch               SHA          Recoverable
--------------------------------------------------------------------------------------------------------------
20240115123456   20240115123456_add_feature_flag.rb       feature/flags        a1b2c3d4     Yes
20240110111111   20240110111111_create_widgets.rb         feature/widgets      e5f6g7h8     Yes

Run 'rails mighost:rollback' to rollback recoverable migrations.
```

### Rollback orphaned migrations

```bash
# Interactive (with confirmation)
rails mighost:rollback

# Force (no confirmation)
FORCE=1 rails mighost:rollback

# Specific version
rails mighost:rollback_version VERSION=20240115123456
```

### Capture existing migrations

If you install Mighost on an existing project:

```bash
rails mighost:capture_existing
```

This captures all migration files that have already been run.

### View stored snapshots

```bash
rails mighost:snapshots
```

### Clean up stale snapshots

Remove snapshots for migrations no longer in `schema_migrations`:

```bash
rails mighost:cleanup
```

## Configuration

```ruby
# config/initializers/mighost.rb
Mighost.configure do |config|
  # Storage mode:
  #   :stealth - Local SQLite file, personal use, no schema changes
  #   :team    - Project database, shared with team, requires migration
  config.storage = :stealth

  # Path to SQLite file (stealth mode)
  config.stealth_storage_path = ".mighost.sqlite3"

  # Table name (team mode)
  config.table_name = :mighost_snapshots

  # Auto-capture on migrate
  config.auto_capture = true

  # Store git metadata
  config.store_git_metadata = true

  # Enable/disable (disabled in production by default)
  config.enabled = !Rails.env.production?
end
```

## How It Works

1. **Capture**: When you run `db:migrate`, Mighost hooks into `ActiveRecord::Migrator` and stores the migration file content along with git metadata (branch, SHA).

2. **Detect**: `mighost:status` compares `schema_migrations` table with actual migration files to find orphans.

3. **Rollback**: `mighost:rollback` writes the stored content to a temp file, loads it, calls the `down` method, then removes the version from `schema_migrations`.

## Limitations

- **Irreversible migrations**: If the migration raises `ActiveRecord::IrreversibleMigration`, Mighost can't help.
- **Model dependencies**: If your migration references models/classes that don't exist in the current branch, the rollback may fail.
- **Manual SQL changes**: If someone manually modified the database, rollback might not work correctly.

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
