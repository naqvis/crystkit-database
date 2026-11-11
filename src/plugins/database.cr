require "base64"
require "../features/database"

module CrystKit
  module Plugins
    # Plugin exposing typed SQLite-style database access to the frontend.
    #
    # Opens connections by logical *name*; when no path is supplied the database is materialized under `config.storage_dir/databases/<name>.db`. Names may contain letters, digits, `_`, and `-`. Bind parameters flow over IPC as `JSON::Any` (strings, ints, floats, bools, `nil`, and `{"$bytes": "<base64>"}` for BLOBs); result rows are `Hash(String, JSON::Any)` keyed by column name, with BLOBs encoded as `{"$bytes": "<base64>"}`.
    #
    # Registers IPC commands:
    #   db.open — Open a database connection
    #   db.close — Close a database connection
    #   db.execute — Execute SQL with parameters
    #   db.execute_script — Execute a multi-statement SQL script
    #   db.query — Run a SELECT query, returning all rows
    #   db.query_one — Run a SELECT query, returning one row
    #   db.migrate — Run pending migrations
    #   db.rollback — Roll back the last migration
    #   db.transaction — Execute multiple SQL statements in a transaction
    #   db.backup — Backup a database to a file
    #   db.restore — Restore a database from a file
    #   db.list — List open databases
    #
    # Long-running commands are asynchronous so the webview stays responsive. Migrations are registered from the host application with `#add_migration`; `db.migrate` and `db.rollback` then act on those migrations.
    #
    # Required capability: `database:access`
    #
    # ```
    # app.plugin(CrystKit::Plugins::Database.new)
    # ```
    class Database < Plugin::Base
      Log = ::Log.for(self)

      # :nodoc: Internal registry of named open database connections.
      @dbs = {} of String => Features::Database
      @migrations = {} of String => Array(Features::Migration)
      @dbs_lock = Mutex.new

      def identifier : String
        "database"
      end

      def metadata : Plugin::Metadata
        commands = %w(db.open db.close db.execute db.execute_script db.query db.query_one db.migrate db.rollback db.transaction db.backup db.restore db.list)
        ipc = IPC::PolicyCatalog.new
          .require(commands, "database:access")

        Plugin::Metadata.new(
          identifier,
          capabilities: %w(database:access),
          commands: commands,
          ipc: ipc,
        )
      end

      # Registers a migration for the named database. Call this before `db.open` (or while the database is open) so `db.migrate`/`db.rollback` have work to do.
      def add_migration(name : String, migration : Features::Migration) : Nil
        name = canonical_name(name)
        @dbs_lock.synchronize do
          migrations = @migrations[name] ||= [] of Features::Migration
          if migrations.any? { |existing| existing.version == migration.version }
            raise Core::Error.new("Duplicate migration version: #{migration.version}", code: "DUPLICATE_MIGRATION")
          end
          @dbs[name]?.try(&.add_migration(migration))
          migrations << migration
          migrations.sort_by!(&.version)
        end
      end

      # `db.open(name, path?)` opens (or creates) a connection; when *path* is `nil` the database is created at `storage_dir/databases/<name>.db`. Reopening an existing name closes the previous connection first. `db.close(name)` closes and removes the named connection (no-op if unknown). `db.query` returns all rows; `db.query_one` returns a single row or `nil`. `db.transaction(name, statements)` runs an array of `{"sql": ..., "params": [...]}` objects inside one transaction. `db.backup(name, dest)` / `db.restore(name, source)` copy a database to or from a filesystem path. `db.list` returns the open connection names.
      #
      # Each command that targets a connection raises `Core::Error` with code `DB_NOT_OPEN` if the name is unknown.
      def initialize_plugin(context : Plugin::Context) : Nil
        context.command "db.open", String, String? do |name, path|
          name = canonical_name(name)
          db_path = if path
                      path == ":memory:" ? Path[":memory:"] : Path[path].expand(home: true)
                    else
                      context.app.config.storage_dir / "databases" / "#{name}.db"
                    end
          context.security.scopes.require!(db_path, Security::Permission::Write) if path && db_path.to_s != ":memory:"
          if db_path.to_s != ":memory:"
            Dir.mkdir_p(db_path.parent.to_s) unless Dir.exists?(db_path.parent.to_s)
          end

          old = nil
          @dbs_lock.synchronize do
            old = @dbs[name]?
            db = Features::Database.new(db_path)
            begin
              @migrations[name]?.try &.each { |migration| db.add_migration(migration) }
            rescue ex
              begin
                db.close
              rescue
              end
              raise ex
            end
            @dbs[name] = db
          end
          old.try do |db|
            begin
              db.close
            rescue ex
              Log.warn { "DB close failed for '#{name}': #{ex.message}" }
            end
          end
          nil
        end

        context.command "db.close", String do |name|
          name = canonical_name(name)
          db = @dbs_lock.synchronize { @dbs.delete(name) }
          db.try do |d|
            begin
              d.close
            rescue ex
              Log.warn { "DB close failed for '#{name}': #{ex.message}" }
            end
          end
        end

        context.async "db.execute", String, String, JSON::Any do |name, sql, params, _cancel|
          db = get_db(name)
          db.execute(sql, json_to_params(params))
        end

        context.async "db.query", String, String, JSON::Any do |name, sql, params, _cancel|
          db = get_db(name)
          rows = db.query(sql, json_to_params(params))
          rows.map do |row|
            row.transform_values { |value| json_db_value(value) }
          end
        end

        context.async "db.query_one", String, String, JSON::Any do |name, sql, params, _cancel|
          db = get_db(name)
          row = db.query_one(sql, json_to_params(params))
          row.try { |row_data| row_data.transform_values { |value| json_db_value(value) } }
        end

        context.async "db.execute_script", String, String do |name, sql, _cancel|
          get_db(name).execute_script(sql)
        end

        context.async "db.migrate", String do |name|
          get_db(name).migrate
        end

        context.async "db.rollback", String do |name|
          get_db(name).rollback
        end

        context.async "db.transaction", String, JSON::Any do |name, statements, _cancel|
          db = get_db(name)
          array = statements.as_a?
          raise Core::Error.new("Transaction statements must be an array", code: "BAD_REQUEST") unless array
          db.transaction do
            array.each do |stmt|
              object = stmt.as_h?
              raise Core::Error.new("Transaction statement must be an object", code: "BAD_REQUEST") unless object
              sql = object["sql"]?.try(&.as_s?) || raise Core::Error.new("Missing 'sql' field in transaction statement", code: "BAD_REQUEST")
              params = object["params"]?.try { |param| json_to_params(param) } || [] of Features::DBValue
              db.execute(sql, params)
            end
          end
        end

        context.async "db.backup", String, String do |name, dest, _cancel|
          dest_path = Path[dest].expand(home: true)
          context.security.scopes.require!(dest_path, Security::Permission::Write)
          get_db(name).backup(dest_path)
        end

        context.async "db.restore", String, String do |name, source, _cancel|
          source_path = Path[source].expand(home: true)
          context.security.scopes.require!(source_path, Security::Permission::Read)
          get_db(name).restore(source_path)
        end

        context.command "db.list" do
          @dbs_lock.synchronize { @dbs.keys }
        end
      end

      def cleanup_plugin : Nil
        @dbs_lock.synchronize do
          @dbs.each_value do |d|
            begin
              d.close
            rescue ex
              Log.warn { "DB cleanup failed: #{ex.message}" }
            end
          end
          @dbs.clear
          @migrations.clear
        end
      end

      # :nodoc:
      private def get_db(name : String) : Features::Database
        name = canonical_name(name)
        @dbs_lock.synchronize { @dbs[name]? } || raise Core::Error.new("Database '#{name}' is not open", code: "DB_NOT_OPEN")
      end

      # :nodoc:
      private def canonical_name(name : String) : String
        raise Core::Error.new("Database name cannot be empty", code: "INVALID_NAME") if name.empty?
        unless name.matches?(/\A[a-zA-Z0-9_\-]+\z/)
          raise Core::Error.new("Database name may only contain letters, digits, '_' and '-'", code: "INVALID_NAME")
        end
        name
      end

      # :nodoc:
      private def json_to_params(params : JSON::Any) : Array(Features::DBValue)
        case params.raw
        when Array
          params.as_a.map { |v| json_to_db_value(v).as(Features::DBValue) }
        when Nil
          [] of Features::DBValue
        else
          raise Core::Error.new("Database parameters must be a JSON array", code: "BAD_REQUEST")
        end
      end

      # :nodoc:
      private def json_db_value(value : Features::DBValue)
        value.is_a?(Bytes) ? {"$bytes" => Base64.strict_encode(value)} : value
      end

      # :nodoc:
      private def json_to_db_value(value : JSON::Any) : Features::DBValue
        case value.raw
        when String  then value.as_s
        when Int64   then value.as_i64
        when Float64 then value.as_f
        when Bool    then value.as_bool
        when Nil     then nil
        when Hash
          encoded = value.as_h["$bytes"]?.try(&.as_s?)
          raise Core::Error.new("BLOB value must be {\"$bytes\": \"<base64>\"}", code: "BAD_VALUE") unless encoded
          begin
            Base64.decode(encoded)
          rescue
            raise Core::Error.new("Invalid Base64 BLOB value", code: "BAD_VALUE")
          end
        else
          raise Core::Error.new("Unsupported database value type: #{value.raw.class}", code: "BAD_VALUE")
        end
      end
    end
  end
end
