<template>
  <div style="display: flex; flex-direction: column; height: 100%">
    <div style="padding: 6px 12px; background: var(--bg-2); border-bottom: 1px solid var(--border); display: flex; gap: 8px; align-items: center">
      <span style="font-size: 11px; color: var(--text-1)">SQL Query</span>
      <div style="flex: 1"></div>
      <button class="btn sm primary" @click="run" :disabled="!conn.connId || query.running"><Icon name="play" :size="14" /> Run</button>
      <button class="btn sm ghost" @click="template" title="Insert a CREATE TABLE template"><Icon name="table" :size="14" /> Table</button>
      <button class="btn sm ghost" @click="dumpSql"><Icon name="clipboard-copy" :size="14" /> Export SQL</button>
      <button class="btn sm ghost" @click="importSql"><Icon name="upload" :size="14" /> Import SQL</button>
    </div>
    <div style="flex: 1 1 auto; min-height: 220px; padding: 0 12px; display: flex">
      <SqlEditor v-model="query.sql" :tables="schema.objects.map(o => o.name)" :columns="columns" height="100%" />
    </div>
    <div v-if="query.error" class="pill error" style="margin: 8px 12px; padding: 8px; white-space: pre-wrap; font-family: var(--font-mono); font-size: 12px">{{ query.error }}</div>
    <ResultGrid v-if="query.result" :columns="dispCols" :rows="dispRows" />
    <div style="border-top: 1px solid var(--border); padding: 6px 12px; font-family: var(--font-mono); font-size: 11px; color: var(--green); max-height: 120px; overflow: auto">
      <div v-for="(l, i) in query.log" :key="i">{{ l.ts }}  {{ l.sql.slice(0, 80) }} <span class="muted" v-if="l.rows != null"> ({{ l.rows }} rows, {{ l.ms }}ms)</span></div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, watch } from 'vue'
import { invoke } from '../ipc'
import { useConnectionsStore } from '../stores/connections'
import { useQueryStore } from '../stores/query'
import { useAppStore } from '../stores/app'
import { useUiStore } from '../stores/ui'
import { useSchemaStore } from '../stores/schema'
import SqlEditor from '../components/SqlEditor.vue'
import ResultGrid from '../components/ResultGrid.vue'
import Icon from '../components/Icon.vue'

const conn = useConnectionsStore()
const query = useQueryStore()
const app = useAppStore()
const ui = useUiStore()
const schema = useSchemaStore()

const columns = computed(() => {
  if (!ui.activeTable) return []
  const obj = schema.objects.find((o) => o.name === ui.activeTable)
  return (obj?.columns ?? []).map((c: any) => c.name)
})

watch(
  () => ui.activeTable,
  (t) => query.syncDefault(t),
  { immediate: true },
)

const dispCols = computed(() => {
  const r = query.result
  if (!r) return []
  return r.columns?.length ? r.columns : (r.rows?.[0] ? Object.keys(r.rows[0]) : [])
})
const dispRows = computed(() => query.result?.rows ?? [])

function run() { if (conn.connId) query.run(conn.connId) }
function template() {
  query.sql = `CREATE TABLE new_table (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);`
}
async function dumpSql() {
  const r = await invoke<{ sql: string }>('sqb.dump_sql', conn.connId)
  await invoke('clipboard:write_text', r.sql)
  app.toast('SQL dump copied to clipboard', 'ok')
}
async function importSql() {
  const res = await invoke<{ path: string; picked: boolean }>('sqb.pick_file')
  if (res.picked) { await invoke('sqb.import_sql', [conn.connId, res.path]); app.toast('SQL imported', 'ok') }
}
</script>
