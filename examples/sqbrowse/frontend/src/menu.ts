import { invoke, listen } from './ipc'
import { watch } from 'vue'
import { useConnectionsStore } from './stores/connections'
import { useUiStore } from './stores/ui'
import { useAppStore } from './stores/app'
import { useSchemaStore } from './stores/schema'

// Builds the native menu bar and system tray entirely from JavaScript,
// mirroring DB4S' feature set. Menu clicks route straight to the existing
// store actions / UI handlers — no Crystal round-trip. Recents are persisted
// in the app store (backend) and reflected live in the "Open Recent" submenu.
export function setupMenus() {
  const conn = useConnectionsStore()
  const ui = useUiStore()
  const app = useAppStore()

  const trayMenu = [
    { id: 'show', label: 'Show SQBrowse' },
    { type: 'separator' },
    { id: 'new_db', label: 'New Database…' },
    { id: 'open_db', label: 'Open Database…' },
    { type: 'separator' },
    { id: 'view_browse', label: 'Browse Data' },
    { type: 'separator' },
    { id: 'quit', label: 'Quit SQBrowse' },
  ]

  // Build the menu bar fresh each time so "Open Recent" reflects the
  // current persisted recents and the enabled/disabled state is correct.
  function buildMenuBar() {
    // Recent entries are identified by index (`recent:0`, `recent:1`, …)
    // and resolved against the already-loaded store data in `conn.recent`,
    // so no path is smuggled through the id and the menu plugin's
    // item_id channel is all we need.
    const recentItems: any[] =
      conn.recent.length > 0
        ? conn.recent.map((r, i) => ({ id: `recent:${i}`, label: r.name }))
        : [{ id: 'recent_none', label: 'No recent databases', enabled: false }]
    recentItems.push({ type: 'separator' })
    recentItems.push({ id: 'clear_recent', label: 'Clear History…' })

    return [
      {
        label: 'SQBrowse',
        items: [
          { id: 'about', label: 'About SQBrowse' },
          { type: 'separator' },
          { id: 'quit', label: 'Quit', accelerator: 'Cmd+Q' },
        ],
      },
      {
        label: 'File',
        items: [
          { id: 'new_db', label: 'New Database…', accelerator: 'Cmd+N' },
          { id: 'open_db', label: 'Open Database…', accelerator: 'Cmd+O' },
          { id: 'open_recent', label: 'Open Recent', items: recentItems },
          { id: 'save_as', label: 'Save Database As…', accelerator: 'Cmd+S' },
          { type: 'separator' },
          {
            label: 'Import',
            items: [
              { id: 'import_csv', label: 'Import Table from CSV…' },
              { id: 'import_sql', label: 'Import from SQL file…' },
            ],
          },
          {
            label: 'Export',
            items: [
              { id: 'export_csv', label: 'Export Table as CSV…' },
              { id: 'export_sql', label: 'Export as SQL file…' },
            ],
          },
          { type: 'separator' },
          { id: 'compact', label: 'Compact Database', accelerator: 'Cmd+K' },
          { id: 'close_db', label: 'Close Database', accelerator: 'Cmd+W' },
        ],
      },
      {
        label: 'Edit',
        items: [
          { id: 'copy', label: 'Copy', accelerator: 'Cmd+C' },
          { id: 'paste', label: 'Paste', accelerator: 'Cmd+V' },
          { type: 'separator' },
          { id: 'find', label: 'Find in SQL Editor', accelerator: 'Cmd+F' },
        ],
      },
      {
        label: 'View',
        items: [
          { id: 'view_browse', label: 'Browse Data', accelerator: 'Cmd+1' },
          { id: 'view_sql', label: 'Execute SQL', accelerator: 'Cmd+2' },
          { id: 'view_schema', label: 'Schema', accelerator: 'Cmd+3' },
          { id: 'view_pragmas', label: 'Pragmas', accelerator: 'Cmd+4' },
          { id: 'view_graph', label: 'Graph', accelerator: 'Cmd+5' },
          { type: 'separator' },
          { id: 'devtools', label: 'Toggle DevTools', accelerator: 'Cmd+Alt+I' },
        ],
      },
      {
        label: 'Tools',
        items: [
          { id: 'new_table', label: 'New Table…', accelerator: 'Cmd+T' },
          { id: 'run_sql', label: 'Execute SQL…', accelerator: 'Cmd+E' },
          { type: 'separator' },
          { id: 'integrity', label: 'Check Database Integrity' },
          { id: 'vacuum', label: 'Vacuum Database' },
        ],
      },
      {
        label: 'Help',
        items: [
          { id: 'about', label: 'About SQBrowse' },
          { id: 'shortcuts', label: 'Keyboard Shortcuts' },
        ],
      },
    ]
  }

  function goto(tab: 'browse' | 'sql' | 'schema' | 'pragmas' | 'graph') {
    ui.activeTab = tab
    ui.activeTable = ''
  }

  async function saveAs() {
    if (!conn.connId) { app.toast('No database open', 'error'); return }
    const path = await invoke<string | null>('dialog.save_file', {
      title: 'Save Database As',
      default_name: 'database.db',
      filters: [{ name: 'SQLite Database', extensions: ['db', 'sqlite', 'sqlite3'] }],
    })
    if (!path) return
    try {
      await invoke('sqb.save_as', [conn.connId, path])
      app.toast('Database saved', 'ok')
    } catch (e: any) { app.setError('Save failed', e.message ?? 'Unknown error') }
  }

  async function exportDb(kind: 'export_csv' | 'export_sql') {
    if (!conn.connId) { app.toast('No database open', 'error'); return }
    const path = await invoke<string | null>('dialog.save_file', {
      title: kind === 'export_sql' ? 'Export as SQL' : 'Export as CSV',
      default_name: kind === 'export_sql' ? 'dump.sql' : 'export.csv',
      filters: [{ name: kind === 'export_sql' ? 'SQL' : 'CSV', extensions: [kind === 'export_sql' ? 'sql' : 'csv'] }],
    })
    if (!path) return
    try {
      const res = await invoke<{ csv?: string; sql?: string }>(
        kind === 'export_sql' ? 'sqb.export_sql' : 'sqb.export_csv',
        kind === 'export_sql' ? [conn.connId] : [conn.connId, 'SELECT * FROM sqlite_master WHERE type="table"'],
      )
      const text = kind === 'export_sql' ? (res.sql ?? '') : (res.csv ?? '')
      await invoke('fs:write', { path, content: text })
      app.toast('Export complete', 'ok')
    } catch (e: any) { app.setError('Export failed', e.message ?? 'Unknown error') }
  }

  async function importSql() {
    if (!conn.connId) { app.toast('No database open', 'error'); return }
    const path = await invoke<string | null>('dialog.open_file', {
      title: 'Import SQL file',
      filters: [{ name: 'SQL', extensions: ['sql', 'txt'] }],
    })
    if (!path) return
    try {
      await invoke('sqb.import_sql', [conn.connId, path])
      app.toast('SQL file executed', 'ok')
      await useSchemaStore().refresh()
    } catch (e: any) { app.setError('Import failed', e.message ?? 'Unknown error') }
  }

  async function runDbCommand(cmd: string, okMsg: string, errMsg: string) {
    if (!conn.connId) { app.toast('No database open', 'error'); return }
    try {
      await invoke(cmd, conn.connId)
      app.toast(okMsg, 'ok')
    } catch (e: any) { app.setError(errMsg, e.message ?? 'Unknown error') }
  }

  async function checkIntegrity() {
    if (!conn.connId) { app.toast('No database open', 'error'); return }
    try {
      const res = await invoke<{ ok: boolean; problems: string[] }>('sqb.integrity_check', conn.connId)
      if (res.ok) app.toast('Integrity check passed', 'ok')
      else app.setError('Integrity check failed', res.problems.join('\n'))
    } catch (e: any) { app.setError('Integrity check failed', e.message ?? 'Unknown error') }
  }

  async function openRecent(path: string) {
    try {
      await conn.open(path)
    } catch (e: any) { app.setError('Open failed', e.message ?? 'Unknown error') }
  }

  async function clearRecent() {
    const ok = await invoke<boolean>('dialog.confirm', {
      title: 'Clear recent history',
      message: 'Remove all recently opened databases from the menu and start screen?',
    })
    if (!ok) return
    try {
      await conn.clearRecent()
    } catch (e: any) { app.setError('Clear history failed', e.message ?? 'Unknown error') }
  }

  function showAbout() {
    invoke('dialog.message', {
      title: 'About SQBrowse',
      message: 'SQBrowse — SQLite3 Database Browser\n\nVersion 1.0.0\nFramework: CrystKit',
      kind: 'info',
    }).catch(() => {})
  }

  async function handle(id: string) {
    // Recent items use index-based ids (`recent:0`, …) resolved against
    // the store-retrieved `conn.recent` list already in memory.
    if (id.startsWith('recent:')) {
      const idx = Number(id.slice('recent:'.length))
      const entry = conn.recent[idx]
      if (entry) await openRecent(entry.path)
      return
    }
    switch (id) {
      case 'about': showAbout(); break
      case 'show':
        await invoke('window.show', 'main').catch(() => {})
        await invoke('window.focus', 'main').catch(() => {})
        break
      case 'quit': await invoke('app.quit').catch(() => {}); break
      case 'new_db': conn.createEmpty(); await useSchemaStore().refresh(); break
      case 'open_db': await conn.pickAndOpen(); break
      case 'save_as': await saveAs(); break
      case 'close_db':
        if (conn.connId) { await conn.close(); ui.activeTab = 'browse'; ui.activeTable = '' }
        break
      case 'import_csv': goto('browse'); break
      case 'import_sql': await importSql(); break
      case 'export_csv': await exportDb('export_csv'); break
      case 'export_sql': await exportDb('export_sql'); break
      case 'compact': await runDbCommand('sqb.vacuum', 'Database compacted', 'Compact failed'); break
      case 'vacuum': await runDbCommand('sqb.vacuum', 'Vacuum complete', 'Vacuum failed'); break
      case 'integrity': await checkIntegrity(); break
      case 'new_table': ui.activeTab = 'browse'; (window as any).__sqbShowCreate?.(); break
      case 'run_sql': case 'view_sql': goto('sql'); break
      case 'view_browse': goto('browse'); break
      case 'view_schema': goto('schema'); break
      case 'view_pragmas': goto('pragmas'); break
      case 'view_graph': goto('graph'); break
      case 'find':
        goto('sql')
        window.dispatchEvent(new CustomEvent('sqb:find'))
        break
      case 'copy': document.execCommand?.('copy'); break
      case 'paste': document.execCommand?.('paste'); break
      case 'devtools': await invoke('window.toggle_devtools').catch(() => {}); break
      case 'shortcuts':
        app.toast('Shortcuts: Cmd+N New · Cmd+O Open · Cmd+S Save · Cmd+1..5 Tabs · Cmd+T Table', 'info')
        break
      case 'clear_recent': await clearRecent(); break
    }
  }

  function rebuild() {
    invoke('menu.build', buildMenuBar()).catch((e) => console.warn('menu.build failed', e))
  }

  listen<{ item_id: string }>('menu.click', (p) => handle(p.item_id))
  listen<{ item_id: string }>('tray.menu_click', (p) => handle(p.item_id))

  rebuild()
  // Keep the "Open Recent" submenu in sync as recents change.
  watch(() => conn.recent, () => rebuild(), { deep: true })

  invoke('tray.create', {
    icon: 'tray_icon.png',
    tooltip: 'SQBrowse — SQLite3 Database Browser',
    menu: trayMenu,
  }).catch((e) => console.warn('tray.create failed', e))
}
