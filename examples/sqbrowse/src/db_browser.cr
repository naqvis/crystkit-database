module SQBrowse
  extend self

  @@connections = {} of String => CrystKit::Features::Database
  @@recent = [] of {name: String, path: String}

  def setup(app : CrystKit::App) : Nil
    # commands registered here in later tasks
    app.command "sqb.connections" do
      @@connections.keys.map { |id| {"conn_id" => id} }
    end

    # Quit the whole application (invoked from the JS-built menu/tray).
    app.command "app.quit" { app.quit }

    app.command "sqb.close", String do |conn_id|
      @@connections.delete(conn_id).try(&.close)
      "ok"
    end

    dialog = CrystKit::Features::FileDialog.new(app.security)

    app.command "sqb.pick_file" do
      filter = CrystKit::Features::FileFilter.new(
        "SQLite Databases",
        ["db", "sqlite", "sqlite3", "db3", "s3db"])
      opts = CrystKit::Features::OpenFileOptions.new(
        title: "Open SQLite Database", filters: [filter])
      path = dialog.open_file(opts)
      path ? {"path" => path.to_s, "picked" => true} : {"path" => "", "picked" => false}
    end

    app.async "sqb.open", String, String do |conn_id, path, _cancel|
      app.security.scopes.require!(Path[path].expand(home: true), CrystKit::Security::Permission::Read)
      unless File.exists?(path)
        raise CrystKit::Core::Error.new("File not found: #{path}", code: "FILE_NOT_FOUND")
      end
      begin
        header = Bytes.new(16)
        File.open(path, "rb", &.read(header))
        unless String.new(header).starts_with?("SQLite format 3")
          raise CrystKit::Core::Error.new(
            "\"#{File.basename(path)}\" is not a SQLite database file.", code: "NOT_SQLITE")
        end
      rescue ex : CrystKit::Core::Error
        raise ex
      rescue ex
        raise CrystKit::Core::Error.new("Cannot read file: #{ex.message}", code: "READ_ERROR")
      end

      @@connections.delete(conn_id).try(&.close)
      @@connections[conn_id] = CrystKit::Features::Database.new(Path[path])
      @@recent.unshift({name: File.basename(path), path: path})
      @@recent.uniq! { |r| r[:path] }
      @@recent = @@recent.first(20)
      {"conn_id" => conn_id, "path" => path, "ok" => true}
    end

    app.command "sqb.recent" do
      @@recent
    end

    app.command "sqb.clear_recent" do
      @@recent = [] of {name: String, path: String}
      "ok"
    end

    app.async "sqb.schema", String do |conn_id, _cancel|
      db = get_conn(conn_id)
      objects = db.query(
        "SELECT name, type FROM sqlite_master WHERE type IN ('table','view','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type, name")

      objects.map do |o|
        oname = o["name"].as(String)
        otype = o["type"].as(String)
        safe = oname.gsub("\"", "\"\"")
        case otype
        when "table", "view"
          cols = db.query("PRAGMA table_info(\"#{safe}\")").map { |c|
            {"cid" => c["cid"], "name" => c["name"], "type" => c["type"],
             "notnull" => c["notnull"], "pk" => c["pk"]}
          }
          row_count = begin
            r = db.query_one("SELECT COUNT(*) as cnt FROM \"#{safe}\"")
            r.not_nil!["cnt"]
          rescue
            nil
          end
          {"name" => oname, "type" => otype, "columns" => cols, "row_count" => row_count, "sql" => ddl(db, oname)}
        else
          {"name" => oname, "type" => otype, "columns" => [] of Hash(String, CrystKit::Features::DBValue), "row_count" => nil, "sql" => ddl(db, oname)}
        end
      end
    end

    app.command "sqb.vacuum", String do |conn_id|
      db = get_conn(conn_id)
      db.execute("VACUUM")
      "ok"
    end

    # Generate a SQL dump (schema + INSERTs) for the whole database.
    app.command "sqb.export_sql", String do |conn_id|
      db = get_conn(conn_id)
      objects = db.query(
        "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view','index','trigger') AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY type, name")
      parts = [] of String
      objects.each do |o|
        parts << "#{o["sql"]};"
        # Dump data only for ordinary tables (skip sqlite_ internals).
        next unless o["type"].as(String) == "table"
        tname = o["name"].as(String)
        next if tname.starts_with?("sqlite_")
        rows = db.query("SELECT * FROM \"#{tname.gsub("\"", "\"\"")}\"")
        next if rows.empty?
        cols = rows.first.not_nil!.keys
        rows.each do |row|
          vals = cols.map { |c| sql_literal(row[c]?) }.join(", ")
          parts << "INSERT INTO \"#{tname}\" (#{cols.map { |c| "\"#{c}\"" }.join(", ")}) VALUES (#{vals});"
        end
      end
      {"sql" => parts.join("\n")}
    end

    # Run PRAGMA integrity_check; returns the list of problems (empty = healthy).
    app.command "sqb.integrity_check", String do |conn_id|
      db = get_conn(conn_id)
      rows = db.query("PRAGMA integrity_check")
      problems = rows.map { |r| r["integrity_check"]?.to_s || "" }.reject(&.==("ok"))
      {"ok" => problems.empty?, "problems" => problems}
    end

    app.async "sqb.create", String, String do |conn_id, path, _cancel|
      app.security.scopes.require!(Path[path].expand(home: true), CrystKit::Security::Permission::Write)
      if File.exists?(path)
        raise CrystKit::Core::Error.new("File already exists: #{path}", code: "FILE_EXISTS")
      end
      @@connections.delete(conn_id).try(&.close)
      @@connections[conn_id] = CrystKit::Features::Database.new(Path[path])
      @@recent.unshift({name: File.basename(path), path: path})
      @@recent.uniq! { |r| r[:path] }
      @@recent = @@recent.first(20)
      {"conn_id" => conn_id, "path" => path, "ok" => true}
    end

    app.async "sqb.create_memory", String do |conn_id, _cancel|
      @@connections.delete(conn_id).try(&.close)
      @@connections[conn_id] = CrystKit::Features::Database.new(Path[":memory:"])
      {"conn_id" => conn_id, "path" => "", "memory" => true, "ok" => true}
    end

    app.async "sqb.save_as", String, String do |conn_id, dest, _cancel|
      app.security.scopes.require!(Path[dest].expand(home: true), CrystKit::Security::Permission::Write)
      db = get_conn(conn_id)
      if File.exists?(dest)
        raise CrystKit::Core::Error.new("File already exists: #{dest}", code: "FILE_EXISTS")
      end
      db.execute("VACUUM INTO ?", [dest] of CrystKit::Features::DBValue)
      @@recent.unshift({name: File.basename(dest), path: dest})
      @@recent.uniq! { |r| r[:path] }
      @@recent = @@recent.first(20)
      {"conn_id" => conn_id, "path" => dest, "ok" => true}
    end

    app.async "sqb.create_table", String, String, JSON::Any do |conn_id, name, cols_json, _cancel|
      db = get_conn(conn_id)
      safe = name.gsub("\"", "\"\"")
      cols = cols_json.as_a
      next {"ok" => false, "reason" => "no columns"} if cols.empty?
      col_defs = cols.map { |c|
        c = c.as_h
        cname = c["name"].as_s
        ctype = (c["type"]?.as?(String) || "TEXT").gsub("\"", "\"\"")
        parts = ["\"#{cname}\"", ctype]
        parts << "PRIMARY KEY" if c["pk"]?.as?(Bool)
        parts << "NOT NULL" if c["notnull"]?.as?(Bool) && !c["pk"]?.as?(Bool)
        parts.join(" ")
      }.join(", ")
      db.execute("CREATE TABLE \"#{safe}\" (#{col_defs})")
      {"ok" => true}
    end

    app.async "sqb.drop_table", String, String do |conn_id, name, _cancel|
      db = get_conn(conn_id)
      safe = name.gsub("\"", "\"\"")
      db.execute("DROP TABLE \"#{safe}\"")
      {"ok" => true}
    end

    app.async "sqb.alter_table_add_col", String, String, JSON::Any do |conn_id, name, col_json, _cancel|
      db = get_conn(conn_id)
      safe = name.gsub("\"", "\"\"")
      c = col_json.as_h
      cname = c["name"].as_s.gsub("\"", "\"\"")
      ctype = (c["type"]?.as?(String) || "TEXT").gsub("\"", "\"\"")
      db.execute("ALTER TABLE \"#{safe}\" ADD COLUMN \"#{cname}\" #{ctype}")
      {"ok" => true}
    end

    app.async "sqb.alter_table_drop_col", String, String, String do |conn_id, name, col, _cancel|
      db = get_conn(conn_id)
      safe = name.gsub("\"", "\"\"")
      db.execute("ALTER TABLE \"#{safe}\" DROP COLUMN \"#{col.gsub("\"", "\"\"")}\"")
      {"ok" => true}
    end

    # Rename a single column (delegates to `Database#rename_column`).
    app.async "sqb.rename_column", String, String, String, String do |conn_id, table, old_col, new_col, _cancel|
      db = get_conn(conn_id)
      db.rename_column(table, old_col, new_col)
      {"ok" => true}
    end

    # Change a column's type / NOT NULL / PK flag (delegates to `Database#modify_column`, which rebuilds the table since this SQLite build lacks `ALTER COLUMN`).
    app.async "sqb.alter_column", String, String, String, JSON::Any do |conn_id, table, col, spec_json, _cancel|
      db = get_conn(conn_id)
      spec = spec_json.as_h
      hash = {} of String => CrystKit::Features::DBValue
      hash["name"] = spec["name"]?.as?(String) || col
      hash["type"] = spec["type"]?.as?(String) || "TEXT"
      hash["pk"] = spec["pk"]?.as?(Bool) || false
      hash["notnull"] = spec["notnull"]?.as?(Bool) || false
      db.modify_column(table, col, hash)
      {"ok" => true}
    rescue ex : CrystKit::Core::Error
      raise ex
    rescue ex
      raise CrystKit::Core::Error.new("Alter column failed: #{ex.message}", code: "ALTER_COLUMN_ERROR")
    end

    app.async "sqb.rename_table", String, String, String do |conn_id, old_name, new_name, _cancel|
      db = get_conn(conn_id)
      old_safe = old_name.gsub("\"", "\"\"")
      new_safe = new_name.gsub("\"", "\"\"")
      db.execute("ALTER TABLE \"#{old_safe}\" RENAME TO \"#{new_safe}\"")
      {"ok" => true}
    end

    app.async "sqb.create_index", String, String, String, String, Bool do |conn_id, table, name, cols, unique, _cancel|
      db = get_conn(conn_id)
      t_safe = table.gsub("\"", "\"\"")
      n_safe = name.gsub("\"", "\"\"")
      col_list = cols.split(",").map(&.strip).reject(&.blank?).map { |c| "\"#{c.gsub("\"", "\"\"")}\"" }.join(", ")
      next {"ok" => false, "reason" => "no columns"} if col_list.blank?
      kind = unique ? "UNIQUE INDEX" : "INDEX"
      db.execute("CREATE #{kind} \"#{n_safe}\" ON \"#{t_safe}\" (#{col_list})")
      {"ok" => true}
    end

    app.async "sqb.drop_index", String, String do |conn_id, name, _cancel|
      db = get_conn(conn_id)
      safe = name.gsub("\"", "\"\"")
      db.execute("DROP INDEX \"#{safe}\"")
      {"ok" => true}
    end

    app.async "sqb.search", String, String, String, Int32, Int32 do |conn_id, table, term, page, per_page, _cancel|
      db = get_conn(conn_id)
      safe = table.gsub("\"", "\"\"")
      cols = db.query("PRAGMA table_info(\"#{safe}\")").map { |c| c["name"].as(String) }
      like = "%#{term.gsub("%", "\\%").gsub("_", "\\_")}%"
      conds = cols.map { |c| "\"#{c.gsub("\"", "\"\"")}\" LIKE ? ESCAPE '\\'" }.join(" OR ")
      params = Array(CrystKit::Features::DBValue).new(cols.size) { like }
      offset = (page - 1) * per_page
      rows = db.query("SELECT * FROM \"#{safe}\" WHERE #{conds} LIMIT ? OFFSET ?", params + [per_page, offset])
      total_row = db.query_one("SELECT COUNT(*) as cnt FROM \"#{safe}\" WHERE #{conds}", params)
      total = case v = total_row.not_nil!["cnt"]
              when Int32 then v.to_i64
              when Int64 then v
              else            0_i64
              end
      {"rows" => rows, "total" => total, "page" => page,
       "pages" => (total.to_f / per_page).ceil.to_i, "columns" => rows.first?.try(&.keys) || [] of String}
    end

    app.async "sqb.table_data", String, String, Int32, Int32, String?, String? do |conn_id, table, page, per_page, sort_col, sort_dir, _cancel|
      db = get_conn(conn_id)
      safe = table.gsub("\"", "\"\"")
      offset = (page - 1) * per_page
      order = if sc = sort_col
                dir = (sort_dir || "ASC").upcase == "DESC" ? "DESC" : "ASC"
                " ORDER BY \"#{sc.gsub("\"", "\"\"")}\" #{dir}"
              else
                ""
              end
      rows = db.query("SELECT * FROM \"#{safe}\"#{order} LIMIT ? OFFSET ?", [per_page, offset] of CrystKit::Features::DBValue)
      total_row = db.query_one("SELECT COUNT(*) as cnt FROM \"#{safe}\"")
      total = case v = total_row.not_nil!["cnt"]
              when Int32 then v.to_i64
              when Int64 then v
              else            0_i64
              end
      {"rows" => rows, "total" => total, "page" => page,
       "pages" => (total.to_f / per_page).ceil.to_i, "columns" => rows.first?.try(&.keys) || [] of String}
    end

    app.async "sqb.update_row", String, String, JSON::Any, JSON::Any do |conn_id, table, pk_json, changes_json, _cancel|
      db = get_conn(conn_id)
      safe = table.gsub("\"", "\"\"")
      pk = pk_json.as_h
      pk_col = pk["col"].as_s.gsub("\"", "\"\"")
      changes = changes_json.as_h
      next {"ok" => false, "reason" => "no changes"} if changes.empty?
      set_clause = changes.keys.map { |k| "\"#{k}\" = ?" }.join(", ")
      params = changes.values.map { |v| json_to_db(v) }
      params << json_to_db(pk["value"])
      db.execute("UPDATE \"#{safe}\" SET #{set_clause} WHERE \"#{pk_col}\" = ?", params)
      {"ok" => true}
    end

    app.async "sqb.insert_row", String, String, JSON::Any do |conn_id, table, values_json, _cancel|
      db = get_conn(conn_id)
      safe = table.gsub("\"", "\"\"")
      values = values_json.as_h
      cols = values.keys.map { |k| "\"#{k}\"" }.join(", ")
      placeholders = values.keys.map { |_| "?" }.join(", ")
      params = values.values.map { |v| json_to_db(v) }
      db.execute("INSERT INTO \"#{safe}\" (#{cols}) VALUES (#{placeholders})", params)
      {"ok" => true}
    end

    app.async "sqb.delete_row", String, String, JSON::Any do |conn_id, table, pk_json, _cancel|
      db = get_conn(conn_id)
      safe = table.gsub("\"", "\"\"")
      pk = pk_json.as_h
      pk_col = pk["col"].as_s.gsub("\"", "\"\"")
      db.execute("DELETE FROM \"#{safe}\" WHERE \"#{pk_col}\" = ?", [json_to_db(pk["value"])] of CrystKit::Features::DBValue)
      {"ok" => true}
    end

    app.async "sqb.export_csv", String, String do |conn_id, sql, _cancel|
      db = get_conn(conn_id)
      rows = db.query(sql)
      next {"csv" => ""} if rows.empty?
      io = IO::Memory.new
      cols = rows.first.not_nil!.keys
      io.puts(cols.map { |c| csv_escape(c) }.join(","))
      rows.each { |row| io.puts(cols.map { |c| csv_escape(row[c]?.try(&.to_s) || "") }.join(",")) }
      {"csv" => io.to_s}
    end

    app.async "sqb.import_csv", String, String, String do |conn_id, table, path, _cancel|
      app.security.scopes.require!(Path[path].expand(home: true), CrystKit::Security::Permission::Read)
      db = get_conn(conn_id)
      safe = table.gsub("\"", "\"\"")
      text = File.read(path)
      rows = parse_csv(text)
      next {"ok" => false, "reason" => "empty file"} if rows.empty?
      header = rows.first.not_nil!.map(&.strip)
      db.transaction do
        rows[1..].each do |fields|
          next if fields.size == 1 && fields.first.blank?
          placeholders = header.map { |_| "?" }.join(", ")
          cols = header.map { |c| "\"#{c}\"" }.join(", ")
          db.execute("INSERT INTO \"#{safe}\" (#{cols}) VALUES (#{placeholders})",
            fields.map { |v| v.as(CrystKit::Features::DBValue) })
        end
      end
      {"ok" => true, "imported" => rows.size - 1}
    end

    app.async "sqb.query", String, String, Int32 do |conn_id, sql, limit, _cancel|
      db = get_conn(conn_id)
      safe = apply_limit(sql, limit > 0 ? limit : 1000)
      started = Time.instant
      rows = db.query(safe)
      ms = (Time.instant - started).total_milliseconds.to_i
      {"rows" => rows, "columns" => rows.first?.try(&.keys) || [] of String,
       "count" => rows.size, "duration_ms" => ms}
    end

    app.async "sqb.execute", String, String do |conn_id, sql, _cancel|
      db = get_conn(conn_id)
      started = Time.instant
      db.execute(sql)
      ms = (Time.instant - started).total_milliseconds.to_i
      {"ok" => true, "duration_ms" => ms}
    end

    app.async "sqb.dump_sql", String do |conn_id, _cancel|
      db = get_conn(conn_id)
      objs = db.query("SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view','index','trigger') AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL ORDER BY type, name")
      io = IO::Memory.new
      objs.each { |o| io.puts("#{o["sql"]};\n") }
      tables = db.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
      tables.each do |t|
        tname = t["name"].as(String)
        cols = db.query("PRAGMA table_info(\"#{tname.gsub("\"", "\"\"")}\")").map { |c| c["name"].as(String) }
        db.query("SELECT * FROM \"#{tname.gsub("\"", "\"\"")}\"").each do |row|
          vals = cols.map { |c| sql_literal(row[c]?) }.join(", ")
          io.puts("INSERT INTO \"#{tname}\" (#{cols.map { |c| "\"#{c}\"" }.join(", ")}) VALUES (#{vals});")
        end
      end
      {"sql" => io.to_s}
    end

    app.async "sqb.import_sql", String, String do |conn_id, path, _cancel|
      app.security.scopes.require!(Path[path].expand(home: true), CrystKit::Security::Permission::Read)
      db = get_conn(conn_id)
      content = File.read(path)
      db.transaction do
        db.execute_script(content)
      end
      {"ok" => true}
    end

    pragmas_list = %w(foreign_keys journal_mode synchronous cache_size temp_store encoding page_size wal_autocheckpoint application_id user_version)

    app.async "sqb.pragmas", String do |conn_id, _cancel|
      db = get_conn(conn_id)
      pragmas_list.map do |p|
        value = begin
          r = db.query_one("PRAGMA #{p}")
          r.try { |row| row.values.first?.try(&.to_s) }
        rescue
          nil
        end
        {"name" => p, "value" => value}
      end
    end

    app.async "sqb.set_pragma", String, String, String do |conn_id, name, value, _cancel|
      db = get_conn(conn_id)
      raise CrystKit::Core::Error.new("Unknown pragma: #{name}", code: "BAD_PRAGMA") unless pragmas_list.includes?(name)
      db.execute("PRAGMA #{name} = #{value}")
      {"ok" => true}
    end

    app.async "sqb.backup", String, String do |conn_id, dest, _cancel|
      app.security.scopes.require!(Path[dest].expand(home: true), CrystKit::Security::Permission::Write)
      get_conn(conn_id).backup(Path[dest].expand(home: true))
      {"ok" => true}
    end

    app.async "sqb.restore", String, String do |conn_id, source, _cancel|
      app.security.scopes.require!(Path[source].expand(home: true), CrystKit::Security::Permission::Read)
      get_conn(conn_id).restore(Path[source].expand(home: true))
      {"ok" => true}
    end

    app.async "sqb.attach", String, String, String do |conn_id, path, alias_name, _cancel|
      app.security.scopes.require!(Path[path].expand(home: true), CrystKit::Security::Permission::Read)
      db = get_conn(conn_id)
      db.execute("ATTACH DATABASE ? AS \"#{alias_name.gsub("\"", "\"\"")}\"", [path] of CrystKit::Features::DBValue)
      {"ok" => true}
    end

    app.async "sqb.graph_data", String, String, String, String, String do |conn_id, source, x, y, agg, _cancel|
      db = get_conn(conn_id)
      from = source.starts_with?("query:") ? "(#{source[6..]})" : "\"#{source.gsub("\"", "\"\"")}\""
      agg_fn = case agg.upcase
               when "SUM" then "SUM"
               when "AVG" then "AVG"
               else            "COUNT"
               end
      sx = x.gsub("\"", "\"\"")
      sy = y.gsub("\"", "\"\"")
      sql = "SELECT \"#{sx}\" AS label, #{agg_fn}(COALESCE(CAST(\"#{sy}\" AS REAL), 0)) AS value FROM #{from} GROUP BY \"#{sx}\" ORDER BY value DESC LIMIT 50"
      rows = db.query(sql)
      {"labels" => rows.map { |r| r["label"]?.try(&.to_s) || "" },
       "values" => rows.map { |r| (r["value"]? || 0).to_s.to_f },
       "x" => x, "y" => y, "agg" => agg}
    rescue ex
      raise CrystKit::Core::Error.new("Graph query failed: #{ex.message}", code: "GRAPH_ERROR")
    end

    app.on_shutdown { cleanup }
  end

  private def apply_limit(sql : String, limit : Int32) : String
    s = sql.strip
    return s if s.upcase.includes?("LIMIT")
    return s unless s.upcase.starts_with?("SELECT") || s.upcase.starts_with?("WITH")
    "#{s} LIMIT #{limit}"
  end

  private def sql_literal(v : CrystKit::Features::DBValue?) : String
    case v
    in String then "'#{v.gsub("'", "''")}'"
    in Nil    then "NULL"
    in Bool   then v ? "1" : "0"
    in Bytes  then "'#{String.new(v).gsub("'", "''")}'"
    in Int32, Int64, Float64
      v.to_s
    end
  end

  private def json_to_db(v : JSON::Any) : CrystKit::Features::DBValue
    case v.raw
    when String  then v.as_s
    when Int64   then v.as_i64
    when Float64 then v.as_f
    when Bool    then v.as_bool
    when Nil     then nil
    else              v.to_s
    end
  end

  private def csv_escape(val : String) : String
    (val.includes?(",") || val.includes?("\"") || val.includes?("\n")) ? "\"#{val.gsub("\"", "\"\"")}\"" : val
  end

  # Parse CSV text into an array of rows (each an array of field strings), honoring double-quoted fields with embedded commas, newlines, and doubled-quote escaping. Mirrors csv_escape output for round-tripping.
  private def parse_csv(text : String) : Array(Array(String))
    rows = [] of Array(String)
    return rows if text.blank?
    current = [] of String
    field = ""
    in_quotes = false
    i = 0
    n = text.size
    while i < n
      c = text[i]
      if in_quotes
        if c == '"'
          if i + 1 < n && text[i + 1] == '"'
            field += '"'
            i += 2
            next
          else
            in_quotes = false
            i += 1
            next
          end
        else
          field += c
          i += 1
          next
        end
      else
        case c
        when '"'
          in_quotes = true
          i += 1
        when ','
          current << field.to_s
          field = ""
          i += 1
        when '\n'
          current << field.to_s
          rows << current
          current = [] of String
          field = ""
          i += 1
        when '\r'
          i += 1
        else
          field += c
          i += 1
        end
      end
    end
    current << field.to_s
    rows << current
    rows
  end

  private def ddl(db : CrystKit::Features::Database, safe_name : String) : String?
    row = db.query_one("SELECT sql FROM sqlite_master WHERE name = ?", safe_name)
    row.try { |r| r["sql"].as?(String) }
  rescue
    nil
  end

  def cleanup : Nil
    @@connections.each_value(&.close)
    @@connections.clear
  end

  private def get_conn(conn_id : String) : CrystKit::Features::Database
    @@connections[conn_id]? || raise CrystKit::Core::Error.new(
      "No open connection. Please open a database file first.", code: "DB_NOT_OPEN")
  end
end
