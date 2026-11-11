# crystkit-database

[![CI](https://github.com/naqvis/crystkit-database/actions/workflows/ci.yml/badge.svg)](https://github.com/naqvis/crystkit-database/actions/workflows/ci.yml)

SQLite database plugin for [CrystKit](https://github.com/naqvis/crystkit).

It adds two pieces:

- `CrystKit::Features::Database` - a typed SQLite abstraction: a single serialized connection, parameterized queries, multi-statement scripts, schema migrations, transactions, backup and restore.
- `CrystKit::Plugins::Database` - an IPC plugin that exposes `db.*` commands to the frontend, gated by the `database:access` capability.

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  crystkit:
    github: naqvis/crystkit
  crystkit-database:
    github: naqvis/crystkit-database
```

Run `shards install`.

SQLite development headers are required to build `crystal-sqlite3`:

- Debian/Ubuntu: `libsqlite3-dev`
- Fedora/RHEL: `sqlite-devel`
- Windows: provide `sqlite3.lib` and `sqlite3.dll`. The CI uses the official SQLite DLL package and generates the import library from `sqlite3.def` with `lib /DEF:sqlite3.def /OUT:sqlite3.lib /MACHINE:X64`, then puts the `.lib` on `CRYSTAL_LIBRARY_PATH` and the `.dll` on `PATH`.

## Usage

Open a database and run parameterized SQL:

```crystal
require "crystkit"
require "crystkit-database"

db = CrystKit::Features::Database.new(Path["app.db"])
db.execute("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)")
db.execute("INSERT INTO posts (title) VALUES (?)", "Hello")
db.query("SELECT id, title FROM posts").each { |row| pp row }
db.close
```

`Features::Database` opens one SQLite connection and serializes access with a reentrant mutex. `#transaction` runs on that same connection, so every `#execute`/`#query`/`#execute_script` call inside the block is part of the transaction and rolls back when the block raises. `:memory:` databases work because there is only one connection.

`#query` returns each row as a `Hash(String, DBValue)`. When a query selects duplicate column names (for example, an unaliased join), the last column with that name wins.

### Scripts

`#execute_script` splits a script on top-level semicolons. It understands single-quoted strings, double-quoted identifiers, backtick/bracket identifiers, `--` line comments, and `/* ... */` block comments. Wrap triggers or other multi-statement blocks in `-- +crystkit begin` / `-- +crystkit end` markers so their interior semicolons are kept together:

```crystal
db.execute_script(<<-SQL)
  CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);
  -- +crystkit begin
  CREATE TRIGGER posts_ai AFTER INSERT ON posts BEGIN
    INSERT INTO audit (message) VALUES ('post inserted');
  END;
  -- +crystkit end
SQL
```

### Schema helpers

`#columns(table)` returns `PRAGMA table_info` rows. `#rename_column` uses SQLite's native `ALTER TABLE ... RENAME COLUMN`. `#modify_column(table, column, spec)` rebuilds the table while preserving the original `CREATE TABLE` definition: other columns, table constraints, defaults, `AUTOINCREMENT`, indexes, and triggers are retained. `spec` accepts `name`, `type`, `pk`, and `notnull`; passing `false` for `pk` or `notnull` explicitly clears the flag. The rebuild refuses virtual tables and runs in one transaction.

```crystal
db.modify_column("posts", "title", {
  "type" => "VARCHAR(255)",
} of String => CrystKit::Features::DBValue)
```

### Backup and restore

`#backup(dest)` checkpoints the WAL, copies to a temporary file, and atomically renames it over `dest`. In-memory databases use `VACUUM INTO`. `#restore(source)` validates the SQLite header, copies to a temporary file, atomically replaces the database, reopens it, and clears the in-memory migration state. Both refuse to run inside an active transaction, and `:memory:` restore is rejected with `UNSUPPORTED`.

### Error codes

Failures raise `CrystKit::Core::Error` with a stable code. Common codes are `DB_CLOSED`, `QUERY_ERROR`, `BAD_REQUEST`, `BAD_VALUE`, `BAD_TABLE`, `BAD_COLUMN`, `INVALID_NAME`, `DUPLICATE_MIGRATION`, `MIGRATION_ORDER`, `MIGRATION_ERROR`, `IRREVERSIBLE_MIGRATION`, `TRANSACTION_ACTIVE`, `UNSUPPORTED`, `FILE_NOT_FOUND`, `INVALID_BACKUP`, `INVALID_PATH`, `BACKUP_BUSY`, `BACKUP_ERROR`, `RESTORE_ERROR`, `SCOPE_DENIED`, and `DB_NOT_OPEN`.

## Migrations

`Features::Database` tracks applied schema versions in a `__schema_migrations` table. Register `Migration` records, then `#migrate` applies pending ones in version order and `#rollback` reverts the last applied one:

```crystal
db = CrystKit::Features::Database.new(Path["app.db"])

db.add_migration(CrystKit::Features::Migration.new(
  1,
  "create posts",
  <<-SQL,
    CREATE TABLE posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL DEFAULT ''
    );
  SQL
  "DROP TABLE posts;"
))

db.migrate   # applies migration v1
db.rollback  # runs its down script
```

Duplicate versions are rejected with `DUPLICATE_MIGRATION`; versions at or below an already-applied version are rejected with `MIGRATION_ORDER`. A migration with an empty `down` is irreversible: `#rollback` raises `IRREVERSIBLE_MIGRATION` and leaves both the table and the version row in place. A failed migration rolls its DDL back and leaves no version row, so it can be retried.

## Plugin

Register the plugin to expose `db.*` commands to the frontend:

```crystal
app.plugin CrystKit::Plugins::Database.new
```

Grant the capability in your capabilities manifest. Explicit file paths also require the matching filesystem scope:

```json
{
  "capabilities": ["database:access"],
  "scopes": {
    "fs": ["~"]
  }
}
```

Long-running commands are asynchronous, so a slow query, migration, or backup does not block the webview. CrystKit decodes a single typed argument from the whole payload and multiple arguments from an array, so `db.close` and `db.migrate` take the name directly while the others take arrays:

| Command | Payload |
| --- | --- |
| `db.open` | `["app_db", null]` or `["app_db", "/path/to/file.db"]` |
| `db.close` | `"app_db"` |
| `db.execute` | `["app_db", "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)", []]` |
| `db.execute_script` | `["app_db", "CREATE TABLE a (id INTEGER); CREATE TABLE b (id INTEGER);"]` |
| `db.query` | `["app_db", "SELECT * FROM notes", []]` |
| `db.query_one` | `["app_db", "SELECT * FROM notes WHERE id = ?", [1]]` |
| `db.migrate` | `"app_db"` |
| `db.rollback` | `"app_db"` |
| `db.transaction` | `["app_db", [{"sql": "INSERT INTO notes (body) VALUES (?)", "params": ["first"]}]]` |
| `db.backup` | `["app_db", "/path/to/backup.db"]` |
| `db.restore` | `["app_db", "/path/to/backup.db"]` |
| `db.list` | `[]` |

Pass `":memory:"` as the path to open an in-memory database.

```js
await ipc.invoke("db.open", ["app_db", null]);
await ipc.invoke("db.execute", [
  "app_db",
  "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)",
  [],
]);
await ipc.invoke("db.query", ["app_db", "SELECT * FROM notes", []]);
```

### Plugin migrations

Register migrations on the plugin from the host application before or after `db.open`:

```crystal
plugin = CrystKit::Plugins::Database.new
plugin.add_migration("app_db", CrystKit::Features::Migration.new(
  1,
  "create notes",
  "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);",
  "DROP TABLE notes;"
))
app.plugin(plugin)
```

`db.migrate` and `db.rollback` then apply or revert those migrations for the named database.

### BLOB values

Rows containing BLOBs return `{"$bytes": "<base64>"}` objects instead of ambiguous plain strings. Pass the same object back as a bind parameter to store the original bytes.

```js
const row = await ipc.invoke("db.query_one", ["app_db", "SELECT payload FROM blobs WHERE id = ?", [1]]);
await ipc.invoke("db.execute", ["app_db", "INSERT INTO blobs (payload) VALUES (?)", [row.payload]]);
```

## Development

Run the specs with:

```sh
crystal spec
```

## License

MIT

## Contributors

- [Ali Naqvi](https://github.com/naqvis) - creator and maintainer
