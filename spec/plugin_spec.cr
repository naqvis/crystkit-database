require "./spec_helper"

private def with_database_app(& : CrystKit::App, String ->)
  SpecHelpers.with_temp_dir do |dir|
    app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
    app.plugin(CrystKit::Plugins::Database.new)
    yield app, dir
  end
end

describe CrystKit::Plugins::Database do
  it "requires database:access for every command" do
    plugin = CrystKit::Plugins::Database.new
    plugin.metadata.commands.each do |command|
      plugin.metadata.ipc.commands[command].capability.should eq("database:access")
    end
  end

  it "opens a default database and round-trips a query" do
    with_database_app do |app, dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        result = frontend.invoke("db.open", JSON.parse(%(["app", null])))
        result.ok?.should be_true
        File.exists?(Path[dir] / "databases" / "app.db").should be_true

        frontend.invoke("db.execute", JSON.parse(%(["app", "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)", []]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "INSERT INTO notes (body) VALUES (?)", ["hello"]]))).ok?.should be_true

        result = frontend.invoke("db.query", JSON.parse(%(["app", "SELECT body FROM notes", []])))
        result.ok?.should be_true
        result.value.not_nil!.as_a.first["body"].as_s.should eq("hello")
      ensure
        frontend.detach
      end
    end
  end

  it "opens an in-memory database with an explicit :memory: path" do
    with_database_app do |app, _dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", ":memory:"]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "CREATE TABLE t (id INTEGER)", []]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "INSERT INTO t VALUES (1)", []]))).ok?.should be_true
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT id FROM t", []]))).value.not_nil!.as_a.size.should eq(1)
      ensure
        frontend.detach
      end
    end
  end

  it "rejects unsafe database names instead of sanitizing collisions" do
    with_database_app do |app, _dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        result = frontend.invoke("db.open", JSON.parse(%(["a/b", null])))
        result.ok?.should be_false
        result.error.not_nil!.code.should eq("INVALID_NAME")
      ensure
        frontend.detach
      end
    end
  end

  it "closes the previous connection when a name is reopened" do
    with_database_app do |app, _dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "CREATE TABLE t (id INTEGER)", []]))).ok?.should be_true
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT name FROM sqlite_master WHERE name = 't'", []]))).value.not_nil!.as_a.size.should eq(1)

        frontend.invoke("db.list", JSON.parse("[]")).value.not_nil!.as_a.size.should eq(1)
        frontend.invoke("db.close", JSON.parse(%("app"))).ok?.should be_true
        frontend.invoke("db.list", JSON.parse("[]")).value.not_nil!.as_a.should be_empty
      ensure
        frontend.detach
      end
    end
  end

  it "rolls back a failed transaction" do
    with_database_app do |app, _dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "CREATE TABLE t (id INTEGER)", []]))).ok?.should be_true

        result = frontend.invoke("db.transaction", JSON.parse(%(["app", [
          {"sql": "INSERT INTO t VALUES (1)", "params": []},
          {"sql": "THIS IS NOT SQL", "params": []}
        ]])))
        result.ok?.should be_false
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT id FROM t", []]))).value.not_nil!.as_a.should be_empty
      ensure
        frontend.detach
      end
    end
  end

  it "applies migrations registered by the application" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      plugin = CrystKit::Plugins::Database.new
      plugin.add_migration("app", CrystKit::Features::Migration.new(1, "create notes", "CREATE TABLE notes (id INTEGER)", "DROP TABLE notes"))
      app.plugin(plugin)
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.migrate", JSON.parse(%("app"))).ok?.should be_true
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT name FROM sqlite_master WHERE name = 'notes'", []]))).value.not_nil!.as_a.size.should eq(1)
      ensure
        frontend.detach
      end
    end
  end

  it "rolls back a registered migration through the plugin" do
    SpecHelpers.with_temp_dir do |dir|
      app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[dir]))
      plugin = CrystKit::Plugins::Database.new
      plugin.add_migration("app", CrystKit::Features::Migration.new(1, "create notes", "CREATE TABLE notes (id INTEGER)", "DROP TABLE notes"))
      app.plugin(plugin)
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.migrate", JSON.parse(%("app"))).ok?.should be_true
        frontend.invoke("db.rollback", JSON.parse(%("app"))).ok?.should be_true
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT name FROM sqlite_master WHERE name = 'notes'", []]))).value.not_nil!.as_a.should be_empty
      ensure
        frontend.detach
      end
    end
  end

  it "rejects non-array parameters" do
    with_database_app do |app, _dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        result = frontend.invoke("db.query", JSON.parse(%(["app", "SELECT 1", {"bad": true}])))
        result.ok?.should be_false
        result.error.not_nil!.code.should eq("BAD_REQUEST")
      ensure
        frontend.detach
      end
    end
  end

  it "requires a write scope for explicit database paths" do
    with_database_app do |app, dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        path = Path[dir] / "custom.db"
        open_payload = JSON::Any.new([
          JSON::Any.new("app"),
          JSON::Any.new(path.to_s),
        ])
        result = frontend.invoke("db.open", open_payload)
        result.ok?.should be_false
        result.error.not_nil!.code.should eq("SCOPE_DENIED")

        app.security.scopes.persist(Path[dir], CrystKit::Security::Permission::Write)
        frontend.invoke("db.open", open_payload).ok?.should be_true
      ensure
        frontend.detach
      end
    end
  end

  it "round-trips BLOB values through query and execute" do
    with_database_app do |app, _dir|
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "CREATE TABLE blobs (data BLOB)", []]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "INSERT INTO blobs (data) VALUES (?)", [{"$bytes": "AQID"}]]))).ok?.should be_true

        row = frontend.invoke("db.query_one", JSON.parse(%(["app", "SELECT data FROM blobs", []]))).value.not_nil!.as_h
        row["data"]["$bytes"].as_s.should eq("AQID")

        insert_payload = JSON::Any.new([
          JSON::Any.new("app"),
          JSON::Any.new("INSERT INTO blobs (data) VALUES (?)"),
          JSON::Any.new([row["data"]]),
        ])
        frontend.invoke("db.execute", insert_payload).ok?.should be_true
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT data FROM blobs", []]))).value.not_nil!.as_a.size.should eq(2)
      ensure
        frontend.detach
      end
    end
  end

  it "backs up and restores through the plugin" do
    with_database_app do |app, dir|
      app.security.scopes.persist(Path[dir], CrystKit::Security::Permission::Write)
      frontend = CrystKit::Test::FakeFrontend.new(app)
      begin
        frontend.invoke("db.open", JSON.parse(%(["app", null]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "CREATE TABLE t (id INTEGER)", []]))).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "INSERT INTO t VALUES (1)", []]))).ok?.should be_true

        backup_path = Path[dir] / "backup.db"
        backup_payload = JSON::Any.new([
          JSON::Any.new("app"),
          JSON::Any.new(backup_path.to_s),
        ])
        frontend.invoke("db.backup", backup_payload).ok?.should be_true
        frontend.invoke("db.execute", JSON.parse(%(["app", "INSERT INTO t VALUES (2)", []]))).ok?.should be_true
        frontend.invoke("db.restore", backup_payload).ok?.should be_true
        frontend.invoke("db.query", JSON.parse(%(["app", "SELECT id FROM t", []]))).value.not_nil!.as_a.size.should eq(1)
      ensure
        frontend.detach
      end
    end
  end

  it "registers long-running commands as async" do
    app = CrystKit::App.new(CrystKit::AppConfig.new(storage_dir: Path[Dir.tempdir]))
    app.plugin(CrystKit::Plugins::Database.new)
    %w(db.execute db.execute_script db.query db.query_one db.migrate db.rollback db.transaction db.backup db.restore).each do |command|
      app.router.command_info?(command).not_nil!.async?.should be_true
    end
  end
end
