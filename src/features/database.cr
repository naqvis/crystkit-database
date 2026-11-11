require "json"
require "log"
require "uri"
require "file_utils"
require "db"
require "sqlite3"

module CrystKit
  module Features
    # Value type for parameterized queries — matches crystal-db's `DB::Any`.
    #
    # Every query parameter and every column value returned by `Database#query` flows through this union. Restricting parameters to `DBValue` keeps the public surface aligned with what crystal-sqlite3 can bind without runtime coercion.
    alias DBValue = String | Int32 | Int64 | Float64 | Bool | Nil | Bytes

    # A database migration definition.
    #
    # `Migration` is an immutable record describing one forward (`#up`) and optional backward (`#down`) schema transition. Migrations are registered with `Database#add_migration` and applied in version order by `Database#migrate`. The `#down` script may be empty when the migration is not reversible.
    struct Migration
      # Monotonically increasing version number; applied in ascending order.
      getter version : Int32
      # Human-readable summary shown in logs when the migration runs.
      getter description : String
      # SQL script executed on `#up`. May contain multiple statements.
      getter up : String
      # SQL script executed on `#rollback`. Empty means irreversible.
      getter down : String

      # Creates a migration with the given *version*, *description*, *up* script, and optional *down* script.
      def initialize(@version : Int32, @description : String, @up : String, @down = "")
      end
    end

    # SQLite database abstraction using crystal-db + crystal-sqlite3.
    #
    # Opens a single connection via `DB.connect("sqlite3://path")`. All queries use crystal-db's parameterized API to prevent SQL injection.
    class Database
      # :nodoc:
      @path : Path
      # :nodoc:
      @db : ::DB::Connection
      # :nodoc:
      @migrations : Array(Migration)
      # :nodoc:
      @applied_versions : Array(Int32)
      # :nodoc:
      @closed : Bool
      # :nodoc:
      @in_transaction : Bool
      # Serializes all access to the connection. Background fibers run on different OS threads; SQLite connections are not safe for concurrent use, so every operation takes this lock. Reentrant so `transaction` → `execute_script` → `execute` can nest on the same fiber without deadlocking.
      # :nodoc:
      @mutex : Mutex

      # Opens the SQLite database at *path*.
      #
      # A single connection is created via `DB.connect("sqlite3://...")` and kept open until `#close` is called.
      def initialize(@path : Path)
        @db = ::DB.connect(self.class.sqlite_uri(@path))
        @migrations = [] of Migration
        @applied_versions = [] of Int32
        @closed = false
        @in_transaction = false
        @mutex = Mutex.new(:reentrant)
      end

      # Build a `sqlite3://` URI from a filesystem path that round-trips through crystal-sqlite3's URI parser on every platform. On Windows the drive-letter colon (e.g. `C:`) breaks naive URI construction because the URI parser interprets it as a port. URL-encoding the path defeats that.
      protected def self.sqlite_uri(path : Path) : String
        "sqlite3://" + URI.encode_www_form(path.to_s)
      end

      # Execute a SQL statement that returns no rows (INSERT, UPDATE, DELETE, DDL).
      #
      # Raises `Core::Error` (code `DB_CLOSED`) if the database has been closed, and `QUERY_ERROR` if the driver raises.
      def execute(sql : String, params : Array(DBValue) = [] of DBValue) : Nil
        raise Core::Error.new("Database is closed", code: "DB_CLOSED") if @closed
        @mutex.synchronize { @db.exec(sql, args: params) }
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::Error.new("Query failed: #{ex.message}", code: "QUERY_ERROR")
      end

      # Variadic convenience overload — `db.execute(sql, "title", "body", 7)` accepts any DBValue-compatible types without `.as(DBValue)` casts.
      #
      # ```
      # db.execute("INSERT INTO posts (title, body) VALUES (?, ?)", "Hi", "Body")
      # ```
      def execute(sql : String, *params : DBValue) : Nil
        execute(sql, params.to_a.map(&.as(DBValue)))
      end

      # Execute a SQL *script* containing one or more `;`-separated statements.
      #
      # The underlying driver (`exec`) compiles only the first statement of a multi-statement string, silently ignoring the rest. This method splits the script into individual statements — respecting single-quoted string literals and `--` line comments — and runs each one in order, so DDL scripts with several `CREATE TABLE`s behave as authored.
      #
      # Statements are not parameterized; use `execute(sql, params)` for those.
      def execute_script(sql : String) : Nil
        @mutex.synchronize do
          split_statements(sql).each { |stmt| execute(stmt) }
        end
      end

      # :nodoc:
      # Patterns for `-- +crystkit begin` / `-- +crystkit end` markers.
      BLOCK_START_RE = /^[ \t]*-- \+crystkit begin[ \t]*\r?$/m
      # :nodoc:
      BLOCK_END_RE = /^[ \t]*-- \+crystkit end[ \t]*\r?$/m
      # :nodoc:
      CONSTRAINT_KEYWORDS = %w(CONSTRAINT PRIMARY NOT NULL UNIQUE CHECK DEFAULT COLLATE REFERENCES GENERATED AS)

      # Split a SQL script into individual statements on top-level `;`.
      #
      # Ignores semicolons inside single-quoted strings, double-quoted identifiers, backtick/bracket identifiers, `--` line comments, and `/* ... */` block comments. Blank statements are dropped.
      #
      # Multi-statement blocks (triggers, functions, etc.) can be wrapped with comment markers to prevent splitting on interior semicolons:
      #
      # ```
      # -- +crystkit begin
      # CREATE TRIGGER ... BEGIN
      #   INSERT ...;
      #   INSERT ...;
      # END;
      # -- +crystkit end
      # ```
      # :nodoc:
      private def split_statements(sql : String) : Array(String)
        # Pre-scan for block marker ranges (character offsets).
        block_ranges = find_block_ranges(sql)

        statements = [] of String
        current = String::Builder.new
        mode = :normal

        chars = sql.chars
        i = 0
        while i < chars.size
          c = chars[i]
          nxt = i + 1 < chars.size ? chars[i + 1] : '\0'

          case mode
          when :single
            current << c
            if c == '\''
              if nxt == '\''
                current << nxt
                i += 1
              else
                mode = :normal
              end
            end
          when :double
            current << c
            if c == '"'
              if nxt == '"'
                current << nxt
                i += 1
              else
                mode = :normal
              end
            end
          when :backtick
            current << c
            if c == '`'
              if nxt == '`'
                current << nxt
                i += 1
              else
                mode = :normal
              end
            end
          when :bracket
            current << c
            if c == ']'
              if nxt == ']'
                current << nxt
                i += 1
              else
                mode = :normal
              end
            end
          when :line_comment
            current << c
            mode = :normal if c == '\n'
          when :block_comment
            current << c
            if c == '*' && nxt == '/'
              current << nxt
              mode = :normal
              i += 1
            end
          else
            case c
            when '\''
              if nxt == '\''
                current << c << nxt
                i += 1
              else
                mode = :single
                current << c
              end
            when '"'
              if nxt == '"'
                current << c << nxt
                i += 1
              else
                mode = :double
                current << c
              end
            when '`'
              mode = :backtick
              current << c
            when '['
              mode = :bracket
              current << c
            when '-'
              if nxt == '-'
                mode = :line_comment
                current << c
              else
                current << c
              end
            when '/'
              if nxt == '*'
                mode = :block_comment
                current << c
              else
                current << c
              end
            when ';'
              if block_ranges.any?(&.includes?(i))
                current << c
              else
                stmt = current.to_s.strip
                statements << stmt unless stmt.empty?
                current = String::Builder.new
              end
            else
              current << c
            end
          end

          i += 1
        end

        last = current.to_s.strip
        statements << last unless last.empty?
        statements
      end

      # Find character ranges of `-- +crystkit begin` … `-- +crystkit end` blocks.
      # :nodoc:
      private def find_block_ranges(sql : String) : Array(Range(Int32, Int32))
        ranges = [] of Range(Int32, Int32)
        pos = 0
        len = sql.size

        while pos < len
          start_match = sql.match(BLOCK_START_RE, pos)
          break unless start_match
          start_begin = start_match.begin(0)
          start_end = start_match.end(0)

          end_match = sql.match(BLOCK_END_RE, start_end)
          break unless end_match
          end_end = end_match.end(0)

          ranges << (start_begin...end_end)
          pos = end_end
        end
        ranges
      end

      # Execute a SELECT query and return rows as an array of hashes.
      #
      # Each row is a `Hash(String, DBValue)` keyed by column name. Integer columns are returned as `Int64` (the driver's native integer type); callers that need `Int32` must narrow explicitly. All other types are returned as-is from the driver union.
      #
      # Raises `Core::Error` (code `DB_CLOSED`) if the database has been closed, and `QUERY_ERROR` on driver failure.
      def query(sql : String, params : Array(DBValue) = [] of DBValue) : Array(Hash(String, DBValue))
        raise Core::Error.new("Database is closed", code: "DB_CLOSED") if @closed
        results = [] of Hash(String, DBValue)
        @mutex.synchronize do
          @db.query(sql, args: params) do |result_set|
            result_set.each do
              row = {} of String => DBValue
              result_set.column_count.times do |i|
                name = result_set.column_name(i)
                # Read as the most permissive union type crystal-db supports
                val = result_set.read(String | Int64 | Float64 | Bytes | Nil)
                row[name] = case val
                            when Int64   then val
                            when Float64 then val
                            when String  then val
                            when Bytes   then val
                            else              nil
                            end
              end
              results << row
            end
          end
        end
        results
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::Error.new("Query failed: #{ex.message}", code: "QUERY_ERROR")
      end

      # Variadic convenience overload for `query`.
      #
      # ```
      # rows = db.query("SELECT * FROM posts WHERE id = ?", 42)
      # ```
      def query(sql : String, *params : DBValue) : Array(Hash(String, DBValue))
        query(sql, params.to_a.map(&.as(DBValue)))
      end

      # Execute a query expecting at most one row.
      #
      # Returns the first row as a hash, or `nil` if the result set is empty. Convenience for `query(sql, params).first?`.
      def query_one(sql : String, params : Array(DBValue) = [] of DBValue) : Hash(String, DBValue)?
        query(sql, params).first?
      end

      # Variadic convenience overload for `query_one`.
      def query_one(sql : String, *params : DBValue) : Hash(String, DBValue)?
        query_one(sql, params.to_a.map(&.as(DBValue)))
      end

      # Return the column definitions of *table* as reported by `PRAGMA table_info`. Each entry is a hash with keys `name`, `type`, `notnull` (`Int32`, 0/1), `pk` (`Int32`, 0/1) and `dflt_value`.
      #
      # Double-quote an identifier for safe interpolation into SQL, escaping any embedded double-quotes per SQLite's quoting rules.
      private def quote_ident(name : String) : String
        "\"#{name.gsub("\"", "\"\"")}\""
      end

      # Raises `Core::Error` (code `BAD_TABLE`) unless *table* exists.
      def columns(table : String) : Array(Hash(String, DBValue))
        rows = query("PRAGMA table_info(#{quote_ident(table)})")
        raise Core::Error.new("Table not found: #{table}", code: "BAD_TABLE") if rows.empty?
        rows
      end

      # Rename a single column with the native `ALTER TABLE ... RENAME COLUMN`.
      #
      # Carries the column's data. Unlike `#modify_column`, this is a metadata operation — it does not rewrite the table, so it is fast and preserves triggers, indexes and rowids. It cannot change the column's type or constraints (use `#modify_column` for that).
      def rename_column(table : String, old_col : String, new_col : String) : Nil
        execute("ALTER TABLE #{quote_ident(table)} RENAME COLUMN #{quote_ident(old_col)} TO #{quote_ident(new_col)}")
      end

      # Change a column's definition (name, type, NOT NULL, PRIMARY KEY).
      #
      # SQLite has no in-place column retype (only `RENAME COLUMN` and `DROP COLUMN` exist), so this rebuilds the table: the original `CREATE TABLE` definition is edited, a new table is created with every other column and table constraint preserved, rows are copied across, the old table dropped, and the new one renamed back. Indexes and triggers are recreated from their stored DDL.
      #
      # *spec* keys: `name` (String), `type` (String), `pk` (Bool), `notnull` (Bool). Any key may be omitted to keep the current value. Passing `false` for `pk` or `notnull` explicitly clears that flag.
      #
      # The whole operation runs inside a transaction; if it raises, the table is left unchanged.
      def modify_column(table : String, col : String, spec : Hash(String, DBValue)) : Nil
        current = columns(table).find { |column| column["name"] == col }
        raise Core::Error.new("Column not found: #{col}", code: "BAD_COLUMN") unless current

        next_name = if spec.has_key?("name")
                      spec["name"].as?(String) || raise Core::Error.new("name must be a string", code: "BAD_VALUE")
                    else
                      col
                    end
        next_type = if spec.has_key?("type")
                      spec["type"].as?(String) || raise Core::Error.new("type must be a string", code: "BAD_VALUE")
                    else
                      current["type"].as(String)
                    end
        next_pk = if spec.has_key?("pk")
                    value = spec["pk"]
                    value.is_a?(Bool) ? value : raise Core::Error.new("pk must be a boolean", code: "BAD_VALUE")
                  else
                    current["pk"].as(Int64) == 1
                  end
        next_nn = if spec.has_key?("notnull")
                    value = spec["notnull"]
                    value.is_a?(Bool) ? value : raise Core::Error.new("notnull must be a boolean", code: "BAD_VALUE")
                  else
                    current["notnull"].as(Int64) == 1
                  end

        raise Core::Error.new("Column name cannot be empty", code: "BAD_VALUE") if next_name.empty?
        raise Core::Error.new("Column type cannot be empty", code: "BAD_VALUE") if next_type.strip.empty?

        current_pk = current["pk"].as(Int64) == 1
        current_nn = current["notnull"].as(Int64) == 1
        name_changed = next_name != col
        needs_rebuild = next_type != current["type"].as(String) ||
                        (spec.has_key?("pk") && next_pk != current_pk) ||
                        (spec.has_key?("notnull") && next_nn != current_nn)

        return unless name_changed || needs_rebuild

        transaction do
          if name_changed
            execute("ALTER TABLE #{quote_ident(table)} RENAME COLUMN #{quote_ident(col)} TO #{quote_ident(next_name)}")
          end
          rebuild_table(table, next_name, next_type, next_pk, next_nn) if needs_rebuild
        end
      end

      # :nodoc:
      private def rebuild_table(table : String, column : String, new_type : String, pk : Bool, notnull : Bool) : Nil
        original_sql = table_create_sql(table)
        parts, suffix = table_parts(original_sql)

        target = parts.find { |part| !table_constraint?(part) && column_name(part) == column }
        raise Core::Error.new("Column not found: #{column}", code: "BAD_COLUMN") unless target

        new_definition = rebuild_column_definition(target, column, new_type, pk, notnull)
        new_parts = parts.map do |part|
          if !table_constraint?(part) && column_name(part) == column
            new_definition
          else
            part
          end
        end

        index_sqls = query("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL", [table] of DBValue)
          .map { |row| row["sql"]?.as?(String) }.compact
        trigger_sqls = query("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?", [table] of DBValue)
          .map { |row| row["sql"]?.as?(String) }.compact

        tmp = "__crystkit_alter_tmp_#{table}"
        execute("CREATE TABLE #{quote_ident(tmp)} (#{new_parts.join(", ")})#{suffix}")
        copy_columns = columns(table).map { |row| quote_ident(row["name"].as(String)) }
        execute("INSERT INTO #{quote_ident(tmp)} (#{copy_columns.join(", ")}) SELECT #{copy_columns.join(", ")} FROM #{quote_ident(table)}")
        execute("DROP TABLE #{quote_ident(table)}")
        execute("ALTER TABLE #{quote_ident(tmp)} RENAME TO #{quote_ident(table)}")
        index_sqls.each { |sql| execute(sql) }
        trigger_sqls.each { |sql| execute(sql) }
      end

      # :nodoc:
      private def table_create_sql(table : String) : String
        row = query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table] of DBValue).first?
        sql = row.try { |result| result["sql"]?.as?(String) }
        raise Core::Error.new("Table not found: #{table}", code: "BAD_TABLE") unless sql
        if sql.lstrip.upcase.starts_with?("CREATE VIRTUAL")
          raise Core::Error.new("Cannot modify a virtual table: #{table}", code: "UNSUPPORTED")
        end
        sql
      end

      # :nodoc:
      private def table_parts(sql : String) : {Array(String), String}
        open = find_unquoted(sql, '(')
        raise Core::Error.new("Could not parse table definition", code: "BAD_TABLE") if open < 0
        close = matching_paren(sql, open)
        raise Core::Error.new("Could not parse table definition", code: "BAD_TABLE") if close < 0
        body = sql[(open + 1)...close]
        suffix = sql[(close + 1)..]
        {split_top_level(body, ','), suffix}
      end

      # :nodoc:
      private def rebuild_column_definition(definition : String, column : String, new_type : String, pk : Bool, notnull : Bool) : String
        _original_name, rest = read_identifier(definition)
        _original_type, constraints = split_type_and_constraints(rest.strip)

        unless pk
          constraints = strip_keyword_phrase(constraints, "PRIMARY KEY")
          constraints = strip_keyword_phrase(constraints, "AUTOINCREMENT")
        end
        unless notnull
          constraints = strip_keyword_phrase(constraints, "NOT NULL")
        end
        if pk && !has_keyword_phrase?(constraints, "PRIMARY KEY")
          constraints = add_phrase(constraints, "PRIMARY KEY")
        end
        if notnull && !has_keyword_phrase?(constraints, "NOT NULL")
          constraints = add_phrase(constraints, "NOT NULL")
        end

        [quote_ident(column), new_type, constraints].reject(&.empty?).join(" ")
      end

      # :nodoc:
      private def table_constraint?(definition : String) : Bool
        upper = definition.lstrip.upcase
        upper.starts_with?("CONSTRAINT ") ||
          upper.starts_with?("PRIMARY KEY") ||
          upper == "UNIQUE" || upper.starts_with?("UNIQUE ") || upper.starts_with?("UNIQUE(") ||
          upper == "CHECK" || upper.starts_with?("CHECK ") || upper.starts_with?("CHECK(") ||
          upper.starts_with?("FOREIGN KEY")
      end

      # :nodoc:
      private def column_name(definition : String) : String
        read_identifier(definition)[0]
      end

      # :nodoc:
      private def read_identifier(text : String) : {String, String}
        chars = text.chars
        i = 0
        while i < chars.size && chars[i].whitespace?
          i += 1
        end
        return {"", ""} if i >= chars.size

        start = i
        if chars[i] == '"' || chars[i] == '`' || chars[i] == '['
          quote = chars[i]
          close = quote == '[' ? ']' : quote
          i += 1
          name = String::Builder.new
          while i < chars.size
            c = chars[i]
            if c == close
              if (quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == close
                name << close
                i += 2
              else
                i += 1
                break
              end
            else
              name << c
              i += 1
            end
          end
          return {name.to_s, text[i..]? || ""}
        end

        while i < chars.size && !chars[i].whitespace? && chars[i] != '('
          i += 1
        end
        {text[start...i], text[i..]? || ""}
      end

      # :nodoc:
      private def split_type_and_constraints(rest : String) : {String, String}
        chars = rest.chars
        quote = '\0'
        depth = 0
        i = 0
        while i < chars.size
          c = chars[i]
          if quote == '\0'
            if depth == 0 && constraint_keyword_at?(rest, i)
              return {rest[0...i].strip, rest[i..].strip}
            end
            case c
            when '('
              depth += 1
            when ')'
              depth -= 1
            when '\'', '"', '`'
              quote = c
            when '['
              quote = ']'
            end
          else
            if c == quote
              if (quote == '\'' || quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == quote
                i += 1
              else
                quote = '\0'
              end
            end
          end
          i += 1
        end
        {rest.strip, ""}
      end

      # :nodoc:
      private def constraint_keyword_at?(text : String, index : Int32) : Bool
        CONSTRAINT_KEYWORDS.any? { |keyword| word_at?(text, index, keyword) }
      end

      # :nodoc:
      private def has_keyword_phrase?(text : String, phrase : String) : Bool
        chars = text.chars
        quote = '\0'
        depth = 0
        i = 0
        while i < chars.size
          c = chars[i]
          if quote == '\0'
            return true if depth == 0 && phrase_at?(text, i, phrase)
            case c
            when '('
              depth += 1
            when ')'
              depth -= 1
            when '\'', '"', '`'
              quote = c
            when '['
              quote = ']'
            end
          else
            if c == quote
              if (quote == '\'' || quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == quote
                i += 1
              else
                quote = '\0'
              end
            end
          end
          i += 1
        end
        false
      end

      # :nodoc:
      private def strip_keyword_phrase(text : String, phrase : String) : String
        chars = text.chars
        result = String::Builder.new
        quote = '\0'
        depth = 0
        i = 0
        while i < chars.size
          c = chars[i]
          if quote == '\0'
            if depth == 0 && (phrase_end = phrase_end(text, i, phrase))
              i = phrase_end
              while i < chars.size && chars[i].whitespace?
                i += 1
              end
              next
            end
            case c
            when '('
              depth += 1
            when ')'
              depth -= 1
            when '\'', '"', '`'
              quote = c
            when '['
              quote = ']'
            end
            result << c
          else
            result << c
            if c == quote
              if (quote == '\'' || quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == quote
                result << chars[i + 1]
                i += 1
              else
                quote = '\0'
              end
            end
          end
          i += 1
        end
        result.to_s.strip
      end

      # :nodoc:
      private def phrase_at?(text : String, index : Int32, phrase : String) : Bool
        !phrase_end(text, index, phrase).nil?
      end

      # :nodoc:
      private def phrase_end(text : String, index : Int32, phrase : String) : Int32?
        pos = index
        phrase.split(' ').each do |word|
          while pos < text.size && text[pos].whitespace?
            pos += 1
          end
          return nil unless word_at?(text, pos, word)
          pos += word.size
        end
        pos
      end

      # :nodoc:
      private def word_at?(text : String, index : Int32, word : String) : Bool
        return false if index < 0 || index + word.size > text.size
        return false unless text[index, word.size].compare(word, case_insensitive: true) == 0

        before = index > 0 ? text[index - 1] : nil
        after = index + word.size < text.size ? text[index + word.size] : nil
        before_ok = before.nil? || !(before.letter? || before.number? || before == '_')
        after_ok = after.nil? || !(after.letter? || after.number? || after == '_')
        before_ok && after_ok
      end

      # :nodoc:
      private def add_phrase(text : String, phrase : String) : String
        text = text.strip
        text.empty? ? phrase : "#{text} #{phrase}"
      end

      # :nodoc:
      private def find_unquoted(text : String, target : Char) : Int32
        chars = text.chars
        quote = '\0'
        i = 0
        while i < chars.size
          c = chars[i]
          if quote == '\0'
            return i if c == target
            case c
            when '\'', '"', '`'
              quote = c
            when '['
              quote = ']'
            end
          else
            if c == quote
              if (quote == '\'' || quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == quote
                i += 1
              else
                quote = '\0'
              end
            end
          end
          i += 1
        end
        -1
      end

      # :nodoc:
      private def matching_paren(text : String, open_index : Int32) : Int32
        chars = text.chars
        quote = '\0'
        depth = 0
        i = open_index
        while i < chars.size
          c = chars[i]
          if quote == '\0'
            case c
            when '('
              depth += 1
            when ')'
              depth -= 1
              return i if depth == 0
            when '\'', '"', '`'
              quote = c
            when '['
              quote = ']'
            end
          else
            if c == quote
              if (quote == '\'' || quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == quote
                i += 1
              else
                quote = '\0'
              end
            end
          end
          i += 1
        end
        -1
      end

      # :nodoc:
      private def split_top_level(body : String, delimiter : Char) : Array(String)
        parts = [] of String
        current = String::Builder.new
        chars = body.chars
        quote = '\0'
        depth = 0
        i = 0
        while i < chars.size
          c = chars[i]
          if quote == '\0'
            if c == delimiter && depth == 0
              parts << current.to_s.strip
              current = String::Builder.new
            else
              case c
              when '('
                depth += 1
              when ')'
                depth -= 1
              when '\'', '"', '`'
                quote = c
              when '['
                quote = ']'
              end
              current << c
            end
          else
            current << c
            if c == quote
              if (quote == '\'' || quote == '"' || quote == '`') && i + 1 < chars.size && chars[i + 1] == quote
                current << chars[i + 1]
                i += 1
              else
                quote = '\0'
              end
            end
          end
          i += 1
        end
        last = current.to_s.strip
        parts << last unless last.empty?
        parts
      end

      # Execute a block within a transaction. Rolls back on exception.
      #
      # The block is run inside `DB::Connection#transaction` on the same connection used by `#execute`, `#query`, and `#execute_script`, so a raise rolls every write back. `Core::Error` values propagate unchanged; other exceptions are wrapped in `Core::Error` (code `QUERY_ERROR`). The reentrant mutex makes it safe to call `#execute` and `#execute_script` from within the block.
      #
      # Raises `Core::Error` (code `DB_CLOSED`) if the database has been closed.
      def transaction(&block : ->) : Nil
        raise Core::Error.new("Database is closed", code: "DB_CLOSED") if @closed
        @mutex.synchronize do
          return block.call if @in_transaction
          @in_transaction = true
          begin
            @db.transaction do |_|
              block.call
            end
          ensure
            @in_transaction = false
          end
        end
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::Error.new("Transaction failed: #{ex.message}", code: "QUERY_ERROR")
      end

      # Add a migration definition.
      #
      # Migrations are kept sorted by `version` after insertion, so the order of `#add_migration` calls does not matter. Duplicate versions are not rejected here; `#migrate` skips already-applied versions, so a duplicate added before migration runs will apply once.
      def add_migration(migration : Migration) : Nil
        if @migrations.any? { |existing| existing.version == migration.version }
          raise Core::Error.new("Duplicate migration version: #{migration.version}", code: "DUPLICATE_MIGRATION")
        end
        unless @applied_versions.empty?
          applied = @applied_versions.max
          if migration.version <= applied
            raise Core::Error.new(
              "Migration version #{migration.version} must be greater than applied version #{applied}",
              code: "MIGRATION_ORDER"
            )
          end
        end
        @migrations << migration
        @migrations.sort_by!(&.version)
      end

      # Apply all pending migrations in version order.
      #
      # Each pending migration's `#up` script is run inside a transaction together with an insert into `__schema_migrations`, so a failure mid-migration leaves the database and the migration log consistent. Successfully applied versions are recorded in memory and logged at info level.
      def migrate : Nil
        @mutex.synchronize do
          ensure_schema_table
          @migrations.each do |migration_item|
            next if @applied_versions.includes?(migration_item.version)
            unless @applied_versions.empty?
              latest_applied = @applied_versions.max
              if migration_item.version < latest_applied
                raise Core::Error.new(
                  "Migration version #{migration_item.version} is older than applied version #{latest_applied}",
                  code: "MIGRATION_ORDER"
                )
              end
            end
            transaction do
              execute_script(migration_item.up)
              execute(
                "INSERT INTO __schema_migrations (version, description, applied_at) VALUES (?, ?, ?)",
                [migration_item.version, migration_item.description, Time.utc.to_s] of DBValue
              )
            end
            @applied_versions << migration_item.version
            Log.info { "Database: applied migration v#{migration_item.version}: #{migration_item.description}" }
          end
        end
      end

      # Roll back the last applied migration.
      #
      # Runs the migration's `#down` script (if non-empty) inside a transaction and removes its row from `__schema_migrations`. No-op if no migrations have been applied or if the last applied version has no corresponding `Migration` registered.
      def rollback : Nil
        @mutex.synchronize do
          ensure_schema_table
          return if @applied_versions.empty?
          last_version = @applied_versions.last
          migration = @migrations.find { |migration_item| migration_item.version == last_version }
          return unless migration

          if migration.down.empty?
            raise Core::Error.new(
              "Migration v#{last_version} is irreversible",
              code: "IRREVERSIBLE_MIGRATION"
            )
          end

          transaction do
            execute_script(migration.down)
            execute(
              "DELETE FROM __schema_migrations WHERE version = ?",
              [last_version] of DBValue
            )
          end
          @applied_versions.delete(last_version)
          Log.info { "Database: rolled back migration v#{last_version}" }
        end
      end

      # Backup the database to *dest*.
      #
      # File-backed databases checkpoint the WAL, copy to a temporary file, then atomically rename it over *dest*. In-memory databases use SQLite's `VACUUM INTO`. The backup is refused while a transaction is active.
      #
      # Raises `Core::Error` (code `DB_CLOSED`) if the database is closed, `TRANSACTION_ACTIVE` inside a transaction, `INVALID_PATH` when *dest* is the database file itself, and `BACKUP_ERROR` on copy failure.
      def backup(dest : Path) : Nil
        raise Core::Error.new("Database is closed", code: "DB_CLOSED") if @closed
        raise Core::Error.new("Cannot back up inside a transaction", code: "TRANSACTION_ACTIVE") if @in_transaction
        @mutex.synchronize do
          if @path.to_s == ":memory:"
            backup_memory(dest)
          else
            backup_file(dest)
          end
        end
        Log.info { "Database: backed up to #{dest}" }
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::Error.new("Backup failed: #{ex.message}", code: "BACKUP_ERROR")
      end

      # Restore the database from *source*.
      #
      # The source must be a SQLite database. It is copied to a temporary file, the current connection is closed, and the temporary file atomically replaces the database. `@applied_versions` is cleared so the next migration pass reloads it from the restored file. In-memory databases are not supported.
      #
      # Raises `Core::Error` (code `DB_CLOSED`) if the database is closed, `TRANSACTION_ACTIVE` inside a transaction, `UNSUPPORTED` for `:memory:`, `FILE_NOT_FOUND` if *source* does not exist, `INVALID_BACKUP` when *source* is not SQLite, and `RESTORE_ERROR` on copy failure.
      def restore(source : Path) : Nil
        raise Core::Error.new("Database is closed", code: "DB_CLOSED") if @closed
        raise Core::Error.new("Cannot restore inside a transaction", code: "TRANSACTION_ACTIVE") if @in_transaction
        if @path.to_s == ":memory:"
          raise Core::Error.new("Cannot restore into an in-memory database", code: "UNSUPPORTED")
        end
        unless File.exists?(source.to_s)
          raise Core::Error.new("Backup file not found: #{source}", code: "FILE_NOT_FOUND")
        end
        validate_sqlite_file(source)

        tmp = temporary_backup_path(@path)
        @mutex.synchronize do
          closed = false
          begin
            FileUtils.cp(source.to_s, tmp.to_s)
            @db.close
            closed = true
            remove_sidecars(@path)
            File.rename(tmp.to_s, @path.to_s)
            @db = ::DB.connect(self.class.sqlite_uri(@path))
            @applied_versions.clear
          rescue ex
            if closed
              begin
                @db = ::DB.connect(self.class.sqlite_uri(@path))
              rescue
              end
            end
            raise ex
          ensure
            File.delete(tmp.to_s) if File.exists?(tmp.to_s)
          end
        end
        Log.info { "Database: restored from #{source}" }
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::Error.new("Restore failed: #{ex.message}", code: "RESTORE_ERROR")
      end

      # :nodoc:
      private def backup_memory(dest : Path) : Nil
        tmp = temporary_backup_path(dest)
        begin
          @db.exec("VACUUM INTO ?", args: [tmp.to_s] of DBValue)
          File.rename(tmp.to_s, dest.to_s)
        ensure
          File.delete(tmp.to_s) if File.exists?(tmp.to_s)
        end
      end

      # :nodoc:
      private def backup_file(dest : Path) : Nil
        if @path.expand(home: true) == dest.expand(home: true)
          raise Core::Error.new("Backup destination must differ from the database path", code: "INVALID_PATH")
        end

        checkpoint = query_one("PRAGMA wal_checkpoint(FULL)")
        busy = checkpoint.try { |row| row["busy"]?.as?(Int64) } || 0_i64
        raise Core::Error.new("Database checkpoint is busy", code: "BACKUP_BUSY") if busy != 0

        tmp = temporary_backup_path(dest)
        begin
          FileUtils.cp(@path.to_s, tmp.to_s)
          File.rename(tmp.to_s, dest.to_s)
        ensure
          File.delete(tmp.to_s) if File.exists?(tmp.to_s)
        end
      end

      # :nodoc:
      private def temporary_backup_path(dest : Path) : Path
        dest.parent / ".#{dest.basename}.crystkit-tmp-#{Process.pid}-#{Time.utc.to_unix_ms}"
      end

      # :nodoc:
      private def remove_sidecars(path : Path) : Nil
        ["-wal", "-shm"].each do |suffix|
          sidecar = Path[path.to_s + suffix]
          File.delete(sidecar.to_s) if File.exists?(sidecar.to_s)
        end
      end

      # :nodoc:
      private def validate_sqlite_file(path : Path) : Nil
        header = Bytes.new(16)
        File.open(path.to_s, "rb") do |file|
          read = file.read(header)
          unless read == 16 && String.new(header) == "SQLite format 3\u0000"
            raise Core::Error.new("Not a SQLite database: #{path}", code: "INVALID_BACKUP")
          end
        end
      rescue ex : Core::Error
        raise ex
      rescue ex
        raise Core::Error.new("Cannot read backup: #{ex.message}", code: "INVALID_BACKUP")
      end

      # Close the database connection.
      #
      # Idempotent: calling `#close` on an already-closed database is a no-op. After this call, every other method raises `Core::Error` (code `DB_CLOSED`).
      def close : Nil
        @mutex.synchronize do
          return if @closed
          @db.close
          @closed = true
        end
      end

      # Returns `true` once `#close` has been called.
      def closed? : Bool
        @closed
      end

      # :nodoc:
      private def ensure_schema_table : Nil
        @applied_versions.clear
        @db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS __schema_migrations (
            version INTEGER PRIMARY KEY,
            description TEXT,
            applied_at TEXT
          )
        SQL
        @db.query("SELECT version FROM __schema_migrations ORDER BY version") do |result_set|
          result_set.each do
            @applied_versions << result_set.read(Int64).to_i32
          end
        end
      rescue ex
        Log.warn { "Database: could not initialize schema table: #{ex.message}" }
        raise Core::Error.new("Could not initialize schema table: #{ex.message}", code: "MIGRATION_ERROR")
      end
    end
  end
end
