# Multi-Database Support Plan

## Current State

Mighost currently only supports the **primary database** via `ActiveRecord::Base.connection`. This works for 99% of Rails apps.

## Goal

Support Rails 6+ multi-database configurations, mirroring `db:migrate` conventions:

```bash
# ENV var approach
rails mighost:status DATABASE=animals

# Namespaced tasks approach
rails mighost:status:animals
```

## Implementation Phases

### Phase 1: ENV Variable Support (Simple)

Add `DATABASE` env var support to all commands.

**Changes required:**

1. **Helper method in tasks.rake:**
```ruby
def mighost_connection
  db_name = ENV["DATABASE"]
  if db_name.present?
    config = ActiveRecord::Base.configurations.configs_for(name: db_name)
    raise "Unknown database: #{db_name}" unless config
    ActiveRecord::Base.establish_connection(config)
  end
  ActiveRecord::Base.connection
end
```

2. **Update OrphanDetector** to accept connection parameter:
```ruby
def detect(connection: ActiveRecord::Base.connection, include_dismissed: false)
  # use connection instead of ActiveRecord::Base.connection
end
```

3. **Stealth mode consideration:**
   - Option A: Single file, store db_name in records
   - Option B: Separate files per database (`.mighost.{db_name}.sqlite3`)

   Recommend Option B for isolation.

4. **Update Snapshot** to use db-specific storage path:
```ruby
def stealth_storage_path
  db_name = ENV["DATABASE"] || "primary"
  ".mighost.#{db_name}.sqlite3"
end
```

**Commands affected:**
- `mighost:status`
- `mighost:scan`
- `mighost:rollback`
- `mighost:dismiss`
- `mighost:undismiss`
- `mighost:dismissed`
- `mighost:list`
- `mighost:cleanup`

### Phase 2: Dynamic Namespaced Tasks (Advanced)

Generate tasks like `mighost:status:animals` dynamically.

**Changes required:**

1. **Read database configurations at load time:**
```ruby
# In tasks.rake
ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |db_config|
  db_name = db_config.name

  namespace :mighost do
    namespace db_name.to_sym do
      desc "Show orphaned migrations for #{db_name} database"
      task status: :environment do
        ENV["DATABASE"] = db_name
        Rake::Task["mighost:status"].invoke
      end

      # ... other tasks
    end
  end
end
```

2. **Avoid duplicate task definitions** - Check if task already exists before defining.

3. **Help command update** - Show available databases:
```
Commands:
  rails mighost:status              Show orphaned migrations (primary)
  rails mighost:status:animals      Show orphaned migrations (animals db)
```

### Phase 3: Team Mode Multi-DB

For team mode (shared database storage), each Rails database would have its own `mighost_snapshots` table.

**Changes required:**

1. **Table name includes db context:**
```ruby
def table_name
  db_name = ENV["DATABASE"] || "primary"
  "mighost_#{db_name}_snapshots"
end
```

2. **Or use single table with db_name column:**
```sql
CREATE TABLE mighost_snapshots (
  ...
  database_name TEXT DEFAULT 'primary'
)
```

Recommend separate tables for cleaner isolation.

## Migration Path

1. **v1.x (current)** - Primary database only
2. **v2.0** - Add ENV var support (Phase 1)
3. **v2.1** - Add namespaced tasks (Phase 2)
4. **v2.2** - Team mode multi-db (Phase 3)

## Testing Strategy

1. **Single DB apps** - Ensure no regression
2. **Multi-DB apps** - Test with sample app having primary + animals databases
3. **Stealth mode** - Verify separate SQLite files per database
4. **Team mode** - Verify separate tables per database

## Open Questions

1. Should `mighost:status` (no db specified) show all databases or just primary?
   - Recommendation: Just primary (matches `db:migrate:status` behavior)

2. Should `mighost:scan` scan all databases when no DATABASE specified?
   - Recommendation: No, explicit is better than implicit

3. How to handle database that exists in config but has no migrations yet?
   - Recommendation: Show empty result, no error

## Example Usage (Future)

```bash
# Check status across databases
rails mighost:status                  # primary
rails mighost:status DATABASE=animals # animals db
rails mighost:status:animals          # same as above

# Scan specific database
rails mighost:scan DATABASE=animals

# Dismiss orphan in specific database
rails mighost:dismiss DATABASE=animals VERSION=20230101..

# List all databases with orphans (future convenience command?)
rails mighost:status:all              # shows summary for each db
```
