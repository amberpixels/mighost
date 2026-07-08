# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-07-08

First public release.

### Fixed

- Ghost migrations whose last touch in git history was a deletion are now
  recoverable: recovery resolves to the last commit where the file existed
  instead of the deleting commit.
- `Mighost::GitMetadata.reset!` no longer permanently disables git detection.
- Worktree paths containing spaces or shell metacharacters are handled correctly.
- Rollback now fails loudly when the migration class cannot be determined from
  the recovered file, instead of guessing among loaded migration classes.

### Changed

- CI matrix (Ruby 3.1–3.4 × Rails 7.1–8.1), packaging cleanup, and expanded
  test coverage in preparation for the public release.

## [0.3.0] - 2026-04-06 (internal)

### Added

- Automatic capture of migration file contents on `db:migrate` into a local
  SQLite store (`.mighost.sqlite3`).
- 3-tier recovery for orphaned ("ghost") migrations: stored snapshots,
  git history across all branches, and other git worktrees.
- Rake tasks: `mighost:status`, `mighost:rollback`, `mighost:scan`,
  `mighost:list`, `mighost:dismiss`, `mighost:undismiss`, `mighost:dismissed`,
  `mighost:cleanup`, `mighost:help`.
- Version range syntax for dismiss/undismiss (`VERSION=a..b`, `a..`, `..b`).
- Stable programmatic interface via `Mighost::API` (used by
  [railbow](https://github.com/amberpixels/railbow)).
- Pluggable UI adapter (`Mighost.ui`) with a zero-dependency `PlainUI` default.
- Git metadata capture: branch, SHA, and author per migration.
- Rails 6.1–8.1 support.

## [0.2.0] - 2026-01-23 (internal)

- Git history recovery, dismiss/undismiss workflow, performance improvements.

## [0.1.0] - 2026-01-21 (internal)

- Initial prototype: snapshot capture and rollback of missing migrations.
