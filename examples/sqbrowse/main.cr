require "crystkit"
require "../../src/crystkit-database"

require "./src/db_browser"

Log.setup do |c|
  c.bind "*", :info, ::Log::IOBackend.new(STDERR)
end

config = CrystKit::AppConfig.new(
  name: "SQBrowse",
  version: "1.0.0",
  identifier: "dev.crystkit.sqbrowse",
  capabilities_manifest: Path[__DIR__] / "capabilities.json",
  frontend_dist: "#{__DIR__}/frontend/dist",
)

app = CrystKit::App.new(config)

# ── Single instance ───────────────────────────────────────────────────────────
instance = CrystKit::Features::SingleInstance.new(config.identifier)
unless instance.acquire
  instance.send_to_existing(ARGV)
  Log.info { "sqlbrowse: already running, forwarding args" }
  exit 0
end
instance.on_receive { |args| app.emit("instance:reactivated", {"args" => args}) }
spawn { instance.listen_for_args }
app.on_shutdown { instance.release }

app.plugin(CrystKit::Plugins::FS.new)
app.plugin(CrystKit::Plugins::Dialog.new)
app.plugin(CrystKit::Plugins::Clipboard.new)
app.plugin(CrystKit::Plugins::MenuBar.new)
app.plugin(CrystKit::Plugins::Tray.new)
app.plugin(CrystKit::Plugins::Window.new)
app.plugin(CrystKit::Plugins::DevTools.new)
app.plugin(CrystKit::Plugins::Store.new)

app.window(
  title: "SQLite3 Database Browser",
  label: "main",
  width: 1280,
  height: 860,
) { |w| w.minimize_to_tray = true }

SQBrowse.setup(app)

app.run
