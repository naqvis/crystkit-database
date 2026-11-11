<template>
  <div class="view-area">
    <Toolbar />
    <div class="split" style="flex: 1">
        <DatabaseOutline @new-table="showCreate = true" @open-object="openObject" />
      <div class="split-right">
        <!-- New-table creation: full right pane, not a floating drawer -->
        <NewTableView
          v-if="showCreate"
          @submit="onCreateTable"
          @created="onTableCreated"
          @cancel="showCreate = false"
        />

        <!-- No database open yet: entry prompt -->
        <div v-else-if="!conn.connId" class="empty-db">
          <div class="empty-db-card">
            <div class="empty-db-icon"><Icon name="database" :size="40" /></div>
            <h3>No database open</h3>
            <p class="muted">Open an existing SQLite file or create a new one to get started.</p>
            <div class="empty-db-actions">
              <button class="btn primary" @click="conn.pickAndOpen()"><Icon name="folder-open" :size="14" /> Open DB…</button>
              <button class="btn ghost" @click="conn.createEmpty(); schema.refresh()"><Icon name="file-plus" :size="14" /> New DB…</button>
            </div>
            <div v-if="conn.recent.length" class="recent-list">
              <div class="nav-section" style="padding: 10px 0 6px">Recent</div>
              <button
                v-for="r in conn.recent"
                :key="r.path"
                class="recent-item"
                @click="conn.open(r.path)"
              >
                <Icon name="file" :size="14" class="muted" />
                <span class="recent-name">{{ r.name }}</span>
                <span class="recent-path">{{ r.path }}</span>
              </button>
            </div>
          </div>
        </div>

        <!-- Database open: global tab bar is always visible -->
        <div v-else style="display: flex; flex-direction: column; height: 100%">
          <div class="tabs" style="display: flex; gap: 4px; padding: 0 12px; border-bottom: 1px solid var(--border)">
            <button class="btn sm ghost" :class="{ primary: ui.activeTab === 'browse' }" @click="gotoTab('browse')"><Icon name="table" :size="14" /> Browse Data</button>
            <button class="btn sm ghost" :class="{ primary: ui.activeTab === 'sql' }" @click="gotoTab('sql')"><Icon name="terminal" :size="14" /> Execute SQL</button>
            <button class="btn sm ghost" :class="{ primary: ui.activeTab === 'schema' }" @click="gotoTab('schema')"><Icon name="git-branch" :size="14" /> Schema</button>
            <button class="btn sm ghost" :class="{ primary: ui.activeTab === 'pragmas' }" @click="gotoTab('pragmas')"><Icon name="sliders-horizontal" :size="14" /> Pragmas</button>
            <button class="btn sm ghost" :class="{ primary: ui.activeTab === 'graph' }" @click="gotoTab('graph')"><Icon name="bar-chart-3" :size="14" /> Graph</button>
          </div>

          <!-- When a table is selected AND we're on the Browse tab, nest its
               Structure/Data/DDL below the global bar. Other global tabs
               (Schema/Pragmas/Graph/SQL) stay reachable with the table selected. -->
          <TableView
            v-if="selected && ui.activeTab === 'browse'"
            :table="selected.name"
            :columns="selected.columns ?? []"
            :indexes="indexesFor(selected.name)"
            :row-count="selected.row_count"
            :ddl="selected.sql"
            :busy="busy"
            @drop-table="dropTable"
            @add-column="addColumn"
            @drop-column="dropColumn"
            @edit-column="editColumn"
            @create-index="createIndex"
            @drop-index="dropIndex"
            @rename-table="renameTable"
          />

          <!-- Non-table object (index/trigger) opened for DDL viewing -->
          <ObjectView
            v-else-if="activeObject"
            :obj="activeObject"
          />

          <!-- Otherwise render the selected global view -->
          <div v-else style="flex: 1; overflow: hidden">
            <!-- Empty database: prompt instead of Browse Data -->
            <div v-if="!hasTables && ui.activeTab === 'browse'" class="empty-db">
              <div class="empty-db-card">
                <div class="empty-db-icon"><Icon name="table-2" :size="40" /></div>
                <h3>This database has no tables</h3>
                <p class="muted">Create your first table with the visual editor, or write the DDL yourself.</p>
                <div class="empty-db-actions">
                  <button class="btn primary" @click="showCreate = true"><Icon name="table" :size="14" /> Create Table</button>
                  <button class="btn ghost" @click="gotoTab('sql')"><Icon name="code" :size="14" /> Write DDL</button>
                </div>
              </div>
            </div>
            <!-- With a table selected but on another tab, Browse still shows its data -->
            <BrowseData v-else-if="ui.activeTab === 'browse'" />
            <ExecuteSql v-else-if="ui.activeTab === 'sql'" />
            <SchemaView v-else-if="ui.activeTab === 'schema'" />
            <Pragmas v-else-if="ui.activeTab === 'pragmas'" />
            <Graph v-else-if="ui.activeTab === 'graph'" />
          </div>
        </div>
      </div>
    </div>

    <div class="toasts">
      <TransitionGroup name="toast">
        <div v-for="t in app.toasts" :key="t.id" class="toast-item" :class="t.kind">{{ t.message }}</div>
      </TransitionGroup>
    </div>
    <div v-if="app.error" class="error-bar">
      <div class="error-bar-body">
        <strong class="error-title">{{ app.error.title }}</strong>
        <pre class="error-detail">{{ app.error.detail }}</pre>
      </div>
      <button class="btn sm ghost" @click="app.clearError()">Dismiss</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { invoke } from './ipc'
import { setupMenus } from './menu'
import { useConnectionsStore } from './stores/connections'
import { useSchemaStore } from './stores/schema'
import { useUiStore } from './stores/ui'
import { useAppStore } from './stores/app'
import Toolbar from './components/Toolbar.vue'
import Icon from './components/Icon.vue'
import DatabaseOutline from './components/DatabaseOutline.vue'
import TableView from './views/TableView.vue'
import NewTableView from './views/NewTableView.vue'
import ObjectView from './views/ObjectView.vue'
import BrowseData from './views/BrowseData.vue'
import ExecuteSql from './views/ExecuteSql.vue'
import Pragmas from './views/Pragmas.vue'
import Graph from './views/Graph.vue'
import SchemaView from './views/Schema.vue'

const app = useAppStore()
const conn = useConnectionsStore()
const schema = useSchemaStore()
const ui = useUiStore()
const busy = ref(false)
const showCreate = ref(false)

const selected = computed(() =>
  ui.activeTable ? schema.objects.find((o) => o.name === ui.activeTable) ?? null : null,
)
// A non-table object (index/trigger) opened from the outline for DDL viewing.
const activeObject = ref<any>(null)

// True once the open database has at least one table. Until then the
// right pane shows an empty-state prompt instead of the Browse-only tabs.
const hasTables = computed(() => schema.objects.some((o: any) => o.type === 'table'))

// Switch to a database-level tab and clear any selected table/object, so the
// global view is always reachable (no dead-end inside a table/object).
function gotoTab(tab: 'browse' | 'sql' | 'schema' | 'pragmas' | 'graph') {
  ui.activeTab = tab
  ui.activeTable = ''
  activeObject.value = null
}

// Open a non-table object (index/trigger) from the outline for DDL viewing.
function openObject(o: any) {
  activeObject.value = o
  ui.activeTable = ''
}
// Selecting a table/view takes over the pane, so drop any open object.
watch(() => ui.activeTable, () => { if (ui.activeTable) activeObject.value = null })

function indexesFor(table: string) {
  return schema.objects
    .filter((o) => o.type === 'index')
    .map((o) => parseIndex(o, table))
    .filter((x): x is { name: string; cols: string; unique: boolean } => x !== null)
}
function parseIndex(o: any, table: string): { name: string; cols: string; unique: boolean } | null {
  const sql = o.sql as string | undefined
  if (!sql) return null
  const m = sql.match(/CREATE\s+(UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?["']?(\w+)["']?\s+ON\s+["']?(\w+)["']?\s*\((.+)\)/i)
  if (!m) return { name: o.name, cols: '', unique: /unique/i.test(sql) }
  if (m[3] !== table) return null
  return { name: m[2], cols: m[4], unique: !!m[1] }
}

async function onCreateTable(payload: { name: string; columns: { name: string; type: string; pk: boolean; notnull: boolean }[] }) {
  busy.value = true
  try {
    await invoke('sqb.create_table', [conn.connId, payload.name, payload.columns])
    app.toast('Table created', 'ok')
    showCreate.value = false
    ui.activeTable = payload.name
    ui.tableTab = 'structure'
    await schema.refresh()
  } catch (e: any) {
    app.setError('Create table failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

// Called after the New Table "DDL Script" mode runs arbitrary DDL.
// If the script created a table we can name, open it in the workspace.
async function onTableCreated(tbl: string) {
  busy.value = true
  try {
    await schema.refresh()
    if (tbl && schema.objects.some((t: any) => t.type === 'table' && t.name === tbl)) {
      ui.activeTable = tbl
      ui.tableTab = 'structure'
      showCreate.value = false
    } else {
      showCreate.value = false
    }
  } finally { busy.value = false }
}

async function dropTable(name: string) {
  const ok = await invoke<boolean>('dialog.confirm', {
    title: 'Drop table',
    message: `Drop table "${name}"? This cannot be undone.`,
  })
  if (!ok) return
  busy.value = true
  try {
    await invoke('sqb.drop_table', [conn.connId, name])
    ui.activeTable = ''
    app.toast('Table dropped', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Drop table failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

async function renameTable(p: { oldName: string; newName: string }) {
  busy.value = true
  try {
    await invoke('sqb.rename_table', [conn.connId, p.oldName, p.newName])
    ui.activeTable = p.newName
    app.toast('Table renamed', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Rename table failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

async function addColumn(payload: { name: string; type: string }) {
  if (!selected.value) return
  busy.value = true
  try {
    await invoke('sqb.alter_table_add_col', [conn.connId, selected.value.name, payload])
    app.toast('Column added', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Add column failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

async function dropColumn(col: string) {
  if (!selected.value) return
  const isLast = (selected.value.columns?.length ?? 0) <= 1
  if (isLast) {
    const ok = await invoke<boolean>('dialog.confirm', {
      title: 'Drop table',
      message: `"${selected.value.name}" has only one column. Dropping it removes the entire table. Continue?`,
    })
    if (!ok) return
    return dropTable(selected.value.name)
  }
  busy.value = true
  try {
    await invoke('sqb.alter_table_drop_col', [conn.connId, selected.value.name, col])
    app.toast('Column dropped', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Drop column failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

async function editColumn(p: { oldName: string; name: string; type: string; pk: boolean; notnull: boolean }) {
  if (!selected.value) return
  const original = selected.value.columns?.find((c: any) => c.name === p.oldName)
  if (!original) return
  const nameChanged = p.name !== p.oldName
  const defChanged = p.type !== original.type || !!p.pk !== !!original.pk || !!p.notnull !== !!original.notnull
  busy.value = true
  try {
    if (nameChanged && !defChanged) {
      await invoke('sqb.rename_column', [conn.connId, selected.value.name, p.oldName, p.name])
    } else if (defChanged) {
      const finalName = p.name
      if (nameChanged) {
        await invoke('sqb.rename_column', [conn.connId, selected.value.name, p.oldName, finalName])
      }
      await invoke('sqb.alter_column', [
        conn.connId,
        selected.value.name,
        nameChanged ? finalName : p.oldName,
        { name: finalName, type: p.type, pk: p.pk, notnull: p.notnull },
      ])
    }
    app.toast('Column updated', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Edit column failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

async function createIndex(payload: { name: string; cols: string; unique: boolean }) {
  if (!selected.value) return
  busy.value = true
  try {
    await invoke('sqb.create_index', [conn.connId, selected.value.name, payload.name, payload.cols, payload.unique])
    app.toast('Index created', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Create index failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

async function dropIndex(name: string) {
  busy.value = true
  try {
    await invoke('sqb.drop_index', [conn.connId, name])
    app.toast('Index dropped', 'ok')
    await schema.refresh()
  } catch (e: any) {
    app.setError('Drop index failed', e.message ?? 'Unknown error')
  } finally { busy.value = false }
}

watch(() => conn.connId, () => schema.refresh())
onMounted(() => {
  // Load persisted recents from the Store plugin BEFORE building the menu,
  // so the "Open Recent" submenu is populated on first paint. Do NOT
  // call refreshRecent() here — it would overwrite the restored list
  // with the (empty) backend session mirror on a fresh restart.
  conn.loadPersisted().then(() => setupMenus())
  // Exposed so the JS-built menu "New Table" item can open the editor.
  ;(window as any).__sqbShowCreate = () => { showCreate.value = true; gotoTab('browse') }
})
</script>

<style scoped>
.empty-db {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
}
.empty-db-card {
  text-align: center;
  max-width: 380px;
  padding: 28px 32px;
  border: 1px solid var(--border);
  border-radius: 10px;
  background: var(--bg-2);
}
.empty-db-icon { font-size: 40px; margin-bottom: 8px; }
.empty-db-card h3 { margin: 0 0 6px; font-size: 15px; }
.empty-db-card p { margin: 0 0 16px; font-size: 13px; }
.empty-db-actions { display: flex; gap: 8px; justify-content: center; }
.recent-list { margin-top: 14px; text-align: left; width: 100%; }
.recent-item {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  padding: 6px 8px;
  margin-bottom: 4px;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg-0);
  cursor: pointer;
  text-align: left;
}
.recent-item:hover { border-color: var(--accent); }
.recent-name { font-size: 13px; }
.recent-path { font-size: 11px; color: var(--text-2, #8b949e); margin-left: auto; max-width: 180px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
