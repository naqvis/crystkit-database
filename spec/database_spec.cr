require "./spec_helper"

describe CrystKit::Features::Database do
  it "creates a database instance" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.closed?.should be_false
      db.close
      db.closed?.should be_true
    end
  end
  it "raises when executing on closed database" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.close
      expect_raises(CrystKit::Core::Error, /closed/) do
        db.execute("SELECT 1")
      end
    end
  end
  it "adds and tracks migrations" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      m = CrystKit::Features::Migration.new(1, "create users", "CREATE TABLE users (id INTEGER)", "DROP TABLE users")
      db.add_migration(m)
      db.migrate
      db.close
    end
  end
  it "runs multi-statement migrations (every CREATE TABLE is applied)" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.add_migration(CrystKit::Features::Migration.new(
        1, "multi",
        <<-SQL,
          CREATE TABLE a (id INTEGER PRIMARY KEY);
          CREATE TABLE b (id INTEGER PRIMARY KEY, label TEXT NOT NULL DEFAULT 'x;y');
          CREATE TABLE c (id INTEGER PRIMARY KEY);
          SQL
        "DROP TABLE c; DROP TABLE b; DROP TABLE a;"
      ))
      db.migrate
      db.query("SELECT id FROM a").size.should eq(0)
      db.query("SELECT id FROM b").size.should eq(0)
      db.query("SELECT id FROM c").size.should eq(0)
      db.close
    end
  end
  it "execute_script ignores semicolons inside string literals and comments" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute_script(<<-SQL)
        CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
        -- a comment with a ; semicolon should be ignored
        INSERT INTO notes (body) VALUES ('a;b;c');
        SQL
      rows = db.query("SELECT body FROM notes")
      rows.size.should eq(1)
      rows.first["body"].should eq("a;b;c")
      db.close
    end
  end
  it "executes transaction block" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      executed = false
      db.transaction { executed = true }
      executed.should be_true
      db.close
    end
  end
  it "rolls back transaction on exception" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      expect_raises(Exception, "intentional") do
        db.transaction { raise "intentional" }
      end
      db.close
    end
  end
  it "backs up database file" do
    SpecHelpers.with_temp_dir do |dir|
      src = Path[dir] / "source.db"
      dst = Path[dir] / "backup.db"
      db = CrystKit::Features::Database.new(src)
      db.execute("CREATE TABLE t (id INTEGER, name TEXT)")
      db.execute("INSERT INTO t VALUES (?, ?)", [1, "hello"] of CrystKit::Features::DBValue)
      db.backup(dst)
      File.exists?(dst.to_s).should be_true
      File.size(dst.to_s).should be > 0
      db.close
      restored = CrystKit::Features::Database.new(dst)
      rows = restored.query("SELECT name FROM t WHERE id = ?", [1] of CrystKit::Features::DBValue)
      rows.size.should eq(1)
      rows.first["name"].should eq("hello")
      restored.close
    end
  end
  it "restores database from backup" do
    SpecHelpers.with_temp_dir do |dir|
      src = Path[dir] / "source.db"
      backup = Path[dir] / "backup.db"
      backup_db = CrystKit::Features::Database.new(backup)
      backup_db.execute("CREATE TABLE t (id INTEGER)")
      backup_db.execute("INSERT INTO t VALUES (?)", [42] of CrystKit::Features::DBValue)
      backup_db.close
      db = CrystKit::Features::Database.new(src)
      db.execute("CREATE TABLE other (x INTEGER)")
      db.restore(backup)
      rows = db.query("SELECT id FROM t")
      rows.size.should eq(1)
      rows.first["id"].should eq(42)
      db.close
    end
  end
  it "raises when restoring from nonexistent backup" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      expect_raises(CrystKit::Core::Error, /not found/) do
        db.restore(Path["/nonexistent/backup.db"])
      end
      db.close
    end
  end
  it "raises when querying a non-existent table" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      expect_raises(CrystKit::Core::Error, /no such table/) do
        db.query("SELECT * FROM anything")
      end
      db.close
    end
  end
  it "query_one returns nil for an empty table" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE empty (id INTEGER)")
      db.query_one("SELECT id FROM empty").should be_nil
      db.close
    end
  end

  it "rolls back writes when the transaction block raises" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE t (id INTEGER)")
      expect_raises(Exception, "intentional") do
        db.transaction do
          db.execute("INSERT INTO t VALUES (?)", [1] of CrystKit::Features::DBValue)
          raise "intentional"
        end
      end
      db.query("SELECT id FROM t").size.should eq(0)
      db.close
    end
  end

  it "supports transactions on an in-memory database" do
    db = CrystKit::Features::Database.new(Path[":memory:"])
    db.execute("CREATE TABLE t (id INTEGER)")
    db.transaction do
      db.execute("INSERT INTO t VALUES (?)", [1] of CrystKit::Features::DBValue)
    end
    db.query("SELECT id FROM t").size.should eq(1)
    db.close
  end

  it "rolls back a failed migration and retries the same error" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.add_migration(CrystKit::Features::Migration.new(
        1, "bad", "CREATE TABLE kept (id INTEGER); THIS IS NOT SQL;", ""
      ))
      expect_raises(CrystKit::Core::Error, /syntax error/) { db.migrate }
      db.query("SELECT name FROM sqlite_master WHERE name = ?", "kept").should be_empty
      db.query("SELECT version FROM __schema_migrations").should be_empty
      expect_raises(CrystKit::Core::Error, /syntax error/) { db.migrate }
      db.close
    end
  end

  it "reports DB_CLOSED for operations on a closed database" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.close
      expect_raises(CrystKit::Core::Error) { db.execute("SELECT 1") }.code.should eq("DB_CLOSED")
      expect_raises(CrystKit::Core::Error) { db.query("SELECT 1") }.code.should eq("DB_CLOSED")
      expect_raises(CrystKit::Core::Error) { db.transaction { } }.code.should eq("DB_CLOSED")
      expect_raises(CrystKit::Core::Error) { db.backup(Path[dir] / "b.db") }.code.should eq("DB_CLOSED")
    end
  end

  it "reports FILE_NOT_FOUND when restoring a missing backup" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      expect_raises(CrystKit::Core::Error) { db.restore(Path[dir] / "missing.db") }.code.should eq("FILE_NOT_FOUND")
      db.close
    end
  end

  it "refuses to roll back an irreversible migration" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.add_migration(CrystKit::Features::Migration.new(1, "irreversible", "CREATE TABLE keep_me (id INTEGER)", ""))
      db.migrate
      expect_raises(CrystKit::Core::Error) { db.rollback }.code.should eq("IRREVERSIBLE_MIGRATION")
      db.query("SELECT name FROM sqlite_master WHERE name = ?", "keep_me").size.should eq(1)
      db.query("SELECT version FROM __schema_migrations").size.should eq(1)
      db.close
    end
  end

  it "rejects duplicate migration versions" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.add_migration(CrystKit::Features::Migration.new(1, "first", "CREATE TABLE a (id INTEGER)", "DROP TABLE a"))
      expect_raises(CrystKit::Core::Error) do
        db.add_migration(CrystKit::Features::Migration.new(1, "second", "CREATE TABLE b (id INTEGER)", "DROP TABLE b"))
      end.code.should eq("DUPLICATE_MIGRATION")
      db.close
    end
  end

  it "splits scripts with double-quoted identifiers and block comments" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute_script(%q{CREATE TABLE "a;b" (x TEXT);})
      db.query("SELECT name FROM sqlite_master WHERE name = ?", "a;b").size.should eq(1)

      db.execute_script(%q{INSERT INTO "a;b" (x) VALUES ('one'); /* block ; comment */ INSERT INTO "a;b" (x) VALUES ('two');})
      db.query(%q{SELECT x FROM "a;b" ORDER BY x}).map { |row| row["x"].as(String) }.should eq(["one", "two"])
      db.close
    end
  end

  it "splits scripts with backtick and bracket identifiers" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute_script("CREATE TABLE `semi;colon` (x TEXT); CREATE TABLE [bracket;name] (y TEXT);")
      db.query("SELECT name FROM sqlite_master WHERE name IN (?, ?)", "semi;colon", "bracket;name").size.should eq(2)
      db.close
    end
  end

  it "keeps block-marker bodies together" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE t (id INTEGER)")
      db.execute("CREATE TABLE log (id INTEGER)")
      db.execute_script(<<-SQL)
        -- +crystkit begin
        CREATE TRIGGER trg AFTER INSERT ON t BEGIN
          INSERT INTO log VALUES (1);
          INSERT INTO log VALUES (2);
        END;
        -- +crystkit end
      SQL

      db.execute("INSERT INTO t VALUES (1)")
      db.query("SELECT id FROM log").size.should eq(2)
      db.close
    end
  end

  it "preserves column constraints and defaults when modifying a column type" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute(<<-SQL)
        CREATE TABLE t (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          email TEXT UNIQUE,
          code TEXT CHECK (length(code) > 2),
          name TEXT NOT NULL DEFAULT 'x'
        )
      SQL

      db.modify_column("t", "name", {"type" => "VARCHAR(100)"} of String => CrystKit::Features::DBValue)
      sql = db.query("SELECT sql FROM sqlite_master WHERE name = ?", "t").first["sql"].as(String)
      sql.should contain("AUTOINCREMENT")
      sql.should contain("UNIQUE")
      sql.should contain("CHECK")
      sql.should contain("DEFAULT 'x'")
      sql.should contain("VARCHAR(100)")

      db.execute("INSERT INTO t (email, code) VALUES (?, ?)", ["a@example.com", "abc"] of CrystKit::Features::DBValue)
      db.query_one("SELECT name FROM t WHERE email = ?", "a@example.com").not_nil!["name"].should eq("x")
      expect_raises(CrystKit::Core::Error) do
        db.execute("INSERT INTO t (email, code) VALUES (?, ?)", ["a@example.com", "abcd"] of CrystKit::Features::DBValue)
      end
      db.close
    end
  end

  it "clears NOT NULL and PRIMARY KEY flags when false" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

      db.modify_column("t", "name", {"notnull" => false} of String => CrystKit::Features::DBValue)
      db.columns("t").find { |column| column["name"] == "name" }.not_nil!["notnull"].should eq(0)

      db.modify_column("t", "id", {"pk" => false} of String => CrystKit::Features::DBValue)
      db.columns("t").find { |column| column["name"] == "id" }.not_nil!["pk"].should eq(0)
      db.close
    end
  end

  it "preserves indexes and triggers when modifying a column type" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
      db.execute("CREATE INDEX idx_name ON t(name)")
      db.execute("CREATE TRIGGER trg_name AFTER INSERT ON t BEGIN SELECT 1; END")

      db.modify_column("t", "name", {"type" => "VARCHAR(100)"} of String => CrystKit::Features::DBValue)

      db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_name'").size.should eq(1)
      db.query("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'trg_name'").size.should eq(1)
      db.close
    end
  end

  it "renames a column through modify_column without losing indexes" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE t (id INTEGER, name TEXT)")
      db.execute("CREATE INDEX idx_name ON t(name)")

      db.modify_column("t", "name", {"name" => "full_name"} of String => CrystKit::Features::DBValue)

      db.columns("t").any? { |column| column["name"] == "full_name" }.should be_true
      db.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_name'").size.should eq(1)
      db.close
    end
  end

  it "refuses to back up inside a transaction" do
    SpecHelpers.with_temp_dir do |dir|
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      db.execute("CREATE TABLE t (id INTEGER)")
      expect_raises(CrystKit::Core::Error) do
        db.transaction do
          db.backup(Path[dir] / "backup.db")
        end
      end.code.should eq("TRANSACTION_ACTIVE")
      db.close
    end
  end

  it "backs up an in-memory database" do
    SpecHelpers.with_temp_dir do |dir|
      dest = Path[dir] / "memory-backup.db"
      db = CrystKit::Features::Database.new(Path[":memory:"])
      db.execute("CREATE TABLE t (id INTEGER)")
      db.execute("INSERT INTO t VALUES (?)", [7] of CrystKit::Features::DBValue)
      db.backup(dest)
      db.close

      restored = CrystKit::Features::Database.new(dest)
      restored.query_one("SELECT id FROM t").not_nil!["id"].should eq(7)
      restored.close
    end
  end

  it "rejects restoring into an in-memory database" do
    SpecHelpers.with_temp_dir do |dir|
      source = Path[dir] / "source.db"
      source_db = CrystKit::Features::Database.new(source)
      source_db.execute("CREATE TABLE t (id INTEGER)")
      source_db.close

      db = CrystKit::Features::Database.new(Path[":memory:"])
      expect_raises(CrystKit::Core::Error) { db.restore(source) }.code.should eq("UNSUPPORTED")
      db.close
    end
  end

  it "refreshes migration state after restore" do
    SpecHelpers.with_temp_dir do |dir|
      backup_path = Path[dir] / "backup.db"
      backup_db = CrystKit::Features::Database.new(backup_path)
      backup_db.add_migration(CrystKit::Features::Migration.new(1, "v1", "CREATE TABLE v1_table (id INTEGER)", "DROP TABLE v1_table"))
      backup_db.migrate
      backup_db.close

      db = CrystKit::Features::Database.new(Path[dir] / "target.db")
      db.add_migration(CrystKit::Features::Migration.new(1, "v1", "CREATE TABLE v1_table (id INTEGER)", "DROP TABLE v1_table"))
      db.add_migration(CrystKit::Features::Migration.new(2, "v2", "CREATE TABLE v2_table (id INTEGER)", "DROP TABLE v2_table"))
      db.migrate
      db.restore(backup_path)
      db.migrate

      db.query("SELECT name FROM sqlite_master WHERE name = ?", "v2_table").size.should eq(1)
      db.close
    end
  end

  it "rejects a non-SQLite restore source" do
    SpecHelpers.with_temp_dir do |dir|
      source = Path[dir] / "not-a-database.txt"
      File.write(source, "this is not sqlite")
      db = CrystKit::Features::Database.new(Path[dir] / "test.db")
      expect_raises(CrystKit::Core::Error) { db.restore(source) }.code.should eq("INVALID_BACKUP")
      db.close
    end
  end

  it "rejects a pending migration older than an applied version" do
    SpecHelpers.with_temp_dir do |dir|
      path = Path[dir] / "test.db"
      first = CrystKit::Features::Database.new(path)
      first.add_migration(CrystKit::Features::Migration.new(2, "v2", "CREATE TABLE v2_table (id INTEGER)", "DROP TABLE v2_table"))
      first.migrate
      first.close

      db = CrystKit::Features::Database.new(path)
      db.add_migration(CrystKit::Features::Migration.new(1, "v1", "CREATE TABLE v1_table (id INTEGER)", "DROP TABLE v1_table"))
      db.add_migration(CrystKit::Features::Migration.new(2, "v2", "CREATE TABLE v2_table (id INTEGER)", "DROP TABLE v2_table"))
      expect_raises(CrystKit::Core::Error) { db.migrate }.code.should eq("MIGRATION_ORDER")
      db.close
    end
  end
end
