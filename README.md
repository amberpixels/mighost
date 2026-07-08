<p align="center">
  <img src="logo.svg" alt="Mighost" width="620">
</p>

<div align="center">

### Rollback Rails migrations even when the migration file is missing.

[![Gem Version](https://img.shields.io/gem/v/mighost)](https://rubygems.org/gems/mighost)
[![CI](https://github.com/amberpixels/mighost/actions/workflows/ci.yml/badge.svg)](https://github.com/amberpixels/mighost/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

</div>

---

## The Problem

When working with Rails migrations across git branches:

1. You run migrations on a feature branch
2. Switch back to `main`
3. Run `db:migrate` - Rails dumps schema including changes from the other branch
4. You can't rollback because the migration files don't exist in current branch

**Usual workaround**: Switch to the other branch, rollback, switch back. Tedious.

## The Solution

Mighost automatically captures migration file contents when they run, enabling rollback even when the original file is not present. It uses a 3-tier recovery strategy:

1. **Stored snapshots** — captured at migration time into a local SQLite file
2. **Git history** — searches across all branches
3. **Worktree recovery** — finds files in other git worktrees

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

Add `.mighost.sqlite3` to your `.gitignore`.

Requires Ruby >= 3.1 and Rails 6.1–8.1.

## Usage

### Check for orphaned migrations

```bash
rails mighost:status
```

### Rollback orphaned migrations

```bash
# Interactive (with confirmation)
rails mighost:rollback

# Force (no confirmation)
FORCE=1 rails mighost:rollback

# Specific version
rails mighost:rollback VERSION=20240115123456
```

### Scan existing migrations & git history

If you install Mighost on an existing project:

```bash
rails mighost:scan
```

### All commands

| Command | Description | Options |
|---------|-------------|---------|
| `mighost:status` | Show orphaned migrations | `DEBUG=1`, `SHOW_DISMISSED=1` |
| `mighost:rollback` | Rollback orphaned migrations | `VERSION=x`, `FORCE=1` |
| `mighost:scan` | Capture migrations + search git | `RESCAN=1` |
| `mighost:list` (`ls`) | List stored migration records | `LIMIT=N` |
| `mighost:dismiss` | Hide migrations from status | `VERSION=x`, `VERSION=a..b`, `OLD=1` |
| `mighost:undismiss` | Restore dismissed migrations | `VERSION=x` |
| `mighost:dismissed` | List dismissed migrations | |
| `mighost:cleanup` | Remove stale records | `FORCE=1` |
| `mighost:help` | Show command reference | |

### Version ranges

```bash
VERSION=20240115123456       # Single version
VERSION=20240110..20240120   # Inclusive range
VERSION=20240110..           # From version onwards
VERSION=..20240120           # Up to version
```

## Configuration

```ruby
# config/initializers/mighost.rb
Mighost.configure do |config|
  # Path to SQLite file (relative to Rails.root)
  config.storage_path = ".mighost.sqlite3"

  # Auto-capture on migrate
  config.auto_capture = true

  # Store git metadata
  config.store_git_metadata = true

  # Enable/disable (disabled in production by default)
  config.enabled = !Rails.env.production?
end
```

## Rich Output with Railbow

By default, Mighost outputs plain, uncolored text. For rich, colorized output with tables, emojis, and git enrichment, use the [railbow](https://github.com/amberpixels/railbow) gem:

```ruby
gem 'railbow'
```

Railbow automatically detects Mighost and enhances its output.

## Public API

Mighost exposes a stable API for programmatic access:

```ruby
# Detect orphaned migrations
Mighost::API.orphaned_migrations                  # => [OrphanedMigration, ...]

# Find snapshots
Mighost::API.find_snapshot("20240115123456")       # => Snapshot or nil
Mighost::API.find_or_recover_snapshot("20240115")  # => Snapshot (with git/worktree fallback)

# Scan and recover
Mighost::API.scan!(rescan: false)                  # => {captured:, git_recovered:, ...}

# Rollback
Mighost::API.rollback_version!("20240115123456")   # raises on failure
```

### UI Adapter

Mighost uses a pluggable UI adapter for output. Replace it to customize formatting:

```ruby
# In your railtie or initializer:
Mighost.ui = YourCustomUI.new
```

The adapter must implement: `render_orphans`, `render_records`, `render_recoverable_list`, `render_scan_details`, `render_scan_results`, `render_dismiss_preview`, `render_dismiss_remaining`, `render_dismissed_list`, `confirm?`, `confirm_each?`, `confirm_dismiss?`, `success`, `error`, `warning`, `info`, `hint`. See [`Mighost::PlainUI`](lib/mighost/plain_ui.rb) for the reference implementation.

## How It Works

1. **Capture**: When you run `db:migrate`, Mighost hooks into `ActiveRecord::Migrator` and stores the migration file content along with git metadata (branch, SHA) in a local SQLite file.

2. **Detect**: `mighost:status` compares `schema_migrations` table with actual migration files to find orphans.

3. **Recover**: For missing files, Mighost searches stored snapshots, git history (all branches), and other git worktrees.

4. **Rollback**: Writes recovered content to a temp file, loads it, calls the `down` method, then removes the version from `schema_migrations`.

## Limitations

- **Irreversible migrations**: If the migration raises `ActiveRecord::IrreversibleMigration`, Mighost can't help.
- **Model dependencies**: If your migration references models/classes that don't exist in the current branch, the rollback may fail.
- **Manual SQL changes**: If someone manually modified the database, rollback might not work correctly.
- **Trust**: Recovered migration code (from snapshots, git history, or worktrees) is executed with the same trust as your own migrations — it is code from your repository, run by you.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/amberpixels/mighost/issues). Run `bundle exec rake` (specs + standardrb) before submitting.

## License

MIT License. See [LICENSE](LICENSE).
