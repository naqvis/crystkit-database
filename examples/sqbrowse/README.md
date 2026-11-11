# SQBrowse

A SQLite database browser built as a CrystKit example app.

## Running

Build the frontend first, then run the Crystal app from the shard root:

```sh
cd frontend
npm install
npm run build
cd ..

crystal run examples/sqbrowse/main.cr
```

## Features

- **Create / open / compact** databases — New DB… (opens an in-memory database immediately), Open DB…, and VACUUM-based compaction.
- **Recent databases** — the last opened/saved databases are persisted across restarts via the Store plugin and exposed through the File ▸ Open Recent menu and the tray menu.
- **Schema outline** — browse tables, views, indexes, and triggers in a left-hand outline. Selecting a table opens it on the Data view by default, with Structure and DDL available as nested sub-tabs.
- **Visual structure editor** — create / drop tables, add / drop / modify columns (rename, retype, NOT NULL, primary key), and create / drop indexes. All changes run real `CREATE` / `ALTER` / `DROP` DDL.
- **Browse Data** — virtualized grid with inline cell editing, add-row, and delete-row keyed on the real primary-key column. Columns are sortable, and records can be searched (LIKE across all columns).
- **Execute SQL** — CodeMirror editor with SQLite syntax highlighting and schema-aware autocomplete, a results grid, and a command/SQL log.
- **Import / export** — CSV import & export and SQL dump import & export.
- **Pragmas** — browse and toggle database pragmas.
- **Graphs** — bar charts with COUNT / SUM / AVG aggregation over a chosen column.
- **Integrity check** — run `PRAGMA integrity_check` against the open database.
- **Preferences** — typed, native preferences (no `JSON::Any` gymnastics), persisted through the Store plugin.
- **Native menu bar & system tray** — the full menu bar (SQBrowse / File / Edit / View / Tools / Help) and tray menu are built entirely in JavaScript via the MenuBar and Tray plugins. The tray supports minimize-to-tray: closing the window hides it, and the tray "Show SQBrowse" item brings it back via the Window plugin.
- **About dialog** — a native, styled About window.

## Architecture

SQBrowse is composed of a Crystal backend (`main.cr` + `src/`) and a Vue 3 + TypeScript frontend (`frontend/`).

**Backend**

- `main.cr` is the composition root. It registers the plugins the app needs — FS, Dialog, Clipboard, MenuBar, Tray, Window, DevTools, and Store — grants the required capabilities, creates the main window (with `minimize_to_tray`), and hands off to `SQBrowse.setup`.
- `src/db_browser.cr` registers the backend IPC commands that the frontend drives: `sqb.open`, `sqb.create`, `sqb.create_memory`, `sqb.save_as`, `sqb.close`, `sqb.connections`, `sqb.schema`, `sqb.table_data`, `sqb.insert_row` / `sqb.update_row` / `sqb.delete_row`, `sqb.query` / `sqb.execute`, `sqb.export_csv`, `sqb.export_sql`, `sqb.import_csv`, `sqb.import_sql`, `sqb.integrity_check`, `sqb.vacuum`, `sqb.recent`, `sqb.clear_recent`, and `app.quit`.

**Frontend**

- `src/menu.ts` builds the native menu bar and tray menu in JavaScript and routes every menu/tray click to a store action. Recent items use index-based ids (`recent:0`, …) resolved against the in-memory recents list.
- `src/stores/connections.ts` is the connection store. It seeds recents from the Store plugin at boot (`loadPersisted`), pushes new entries on open/save (`pushRecent` / `persistRecent`), and clears them (`clearRecent` → `store.delete`). Recents are persisted entirely through the Store plugin's `store.set` / `store.get` / `store.delete` IPC — no backend round-trip.
- `src/App.vue` wires the global tab bar (Browse Data / Execute SQL / Schema / Pragmas / Graph) and loads persisted recents before building the menus.
- `src/views/*` holds the feature views: `BrowseData`, `ExecuteSql`, `Schema`, `Pragmas`, `Graph`, `TableView`, `NewTableView`, and `ObjectView` (for index / trigger / view DDL).
- `src/components/DatabaseOutline.vue` drives table selection and defaults a selected table to the Data sub-tab.

**IPC conventions**

- Single-argument commands are invoked with a bare value; multi-argument commands use an array.
- Plugin commands are dot-namespaced: `menu.build`, `tray.create`, `window.show`, `store.set`, `app.quit`. A colon form (e.g. `store:set`) will silently fail with COMMAND_NOT_FOUND.

## Capabilities

The app requests the following capabilities (`capabilities.json`): `database:access`, `fs:read`, `fs:write`, `dialog:open`, `dialog:save`, `clipboard:read`, `clipboard:write`, `menu:manage`, `tray:manage`, `window:manage`, `store:manage`.
