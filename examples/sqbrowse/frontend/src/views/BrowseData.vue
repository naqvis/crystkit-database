<template>
  <div style="display: flex; flex-direction: column; height: 100%">
    <div style="padding: 6px 12px; background: var(--bg-2); border-bottom: 1px solid var(--border); display: flex; gap: 8px; align-items: center; flex-wrap: wrap">
      <span style="font-family: var(--font-mono); font-size: 12px; color: var(--accent)">{{ tableName }}</span>
      <span class="muted">{{ loaded }} / {{ total }} rows</span>
      <span v-if="searchTerm" class="pill muted">search: "{{ searchTerm }}"</span>
      <div style="flex: 1"></div>
      <input
        class="input sm"
        style="width: 180px"
        placeholder="Search this table…"
        :value="searchTerm"
        @input="onSearchInput($event)"
      />
      <button class="btn sm ghost" @click="clearSearch" v-if="searchTerm">Clear</button>
      <button class="btn sm ghost" @click="exportCsv"><Icon name="download" :size="14" /> Export CSV</button>
      <button class="btn sm ghost" @click="importCsv"><Icon name="upload" :size="14" /> Import CSV</button>
      <button class="btn sm ghost" @click="showAdd = !showAdd" :disabled="!columns.length"><Icon name="plus" :size="14" /> Add Row</button>
    </div>
    <div ref="scroller" class="table-scroll" @scroll="onScroll">
      <ResultGrid
        v-if="columns.length"
        :columns="columns"
        :rows="rows"
        editable
        :pk-col="pkCol"
        :show-add="showAdd"
        sortable
        :active-sort="sortCol ? { col: sortCol, dir: sortDir } : null"
        @cell-edit="onCellEdit"
        @row-delete="deleteRow"
        @row-add="onRowAdd"
        @add-cancel="showAdd = false"
        @sort="toggleSort"
      />
      <div v-if="loadingMore" class="muted" style="padding: 12px; text-align: center">Loading more…</div>
      <div v-else-if="rows.length && rows.length >= total" class="muted" style="padding: 12px; text-align: center">— end —</div>
      <div v-if="!rows.length && !loading" class="empty"><p>No rows.</p></div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { invoke } from '../ipc'
import { useConnectionsStore } from '../stores/connections'
import { useUiStore } from '../stores/ui'
import { useSchemaStore } from '../stores/schema'
import { useAppStore } from '../stores/app'
import ResultGrid from '../components/ResultGrid.vue'
import Icon from '../components/Icon.vue'

const props = defineProps<{ singleTable?: string }>()

const conn = useConnectionsStore()
const ui = useUiStore()
const schema = useSchemaStore()
const app = useAppStore()

const tableName = computed(() => props.singleTable ?? ui.activeTable)
const perPage = 200
const rows = ref<any[]>([])
const columns = ref<string[]>([])
const total = ref(0)
const loaded = computed(() => rows.value.length)
const loading = ref(false)
const loadingMore = ref(false)
const scroller = ref<HTMLDivElement | null>(null)
const searchTerm = ref('')
const showAdd = ref(false)
const sortCol = ref<string | null>(null)
const sortDir = ref<'ASC' | 'DESC'>('ASC')

const pkCol = computed(() => {
  const tbl = schema.objects.find((o) => o.name === tableName.value)
  return (tbl?.columns ?? []).find((c: any) => c.pk)?.name ?? ''
})

async function loadInitial() {
  if (!conn.connId || !tableName.value) { rows.value = []; columns.value = []; total.value = 0; return }
  loading.value = true
  try {
    const r = await fetchData(1)
    columns.value = r.columns ?? []
    rows.value = r.rows ?? []
    total.value = r.total ?? 0
  } catch (e: any) {
    app.setError('Load failed', e.message ?? 'Unknown error')
  }
  loading.value = false
}

async function fetchData(page: number) {
  if (searchTerm.value) {
    return await invoke<any>('sqb.search', [conn.connId, tableName.value, searchTerm.value, page, perPage])
  }
  return await invoke<any>('sqb.table_data', [conn.connId, tableName.value, page, perPage, sortCol.value, sortDir.value])
}

function toggleSort(col: string) {
  if (sortCol.value === col) {
    sortDir.value = sortDir.value === 'ASC' ? 'DESC' : 'ASC'
  } else {
    sortCol.value = col
    sortDir.value = 'ASC'
  }
  loadInitial()
}

async function loadMore() {
  if (loadingMore.value || rows.value.length >= total.value) return
  loadingMore.value = true
  const nextPage = Math.floor(rows.value.length / perPage) + 1
  try {
    const r = await fetchData(nextPage)
    rows.value = rows.value.concat(r.rows ?? [])
  } catch (e: any) {
    app.setError('Load more failed', e.message ?? 'Unknown error')
  }
  loadingMore.value = false
}

function onScroll() {
  const el = scroller.value
  if (!el) return
  if (el.scrollTop + el.clientHeight >= el.scrollHeight - 120) loadMore()
}

async function onSearchInput(ev: Event) {
  searchTerm.value = (ev.target as HTMLInputElement).value
  await loadInitial()
}
async function clearSearch() {
  searchTerm.value = ''
  await loadInitial()
}

async function exportCsv() {
  const sql = searchTerm.value
    ? `SELECT * FROM "${tableName.value}"`
    : `SELECT * FROM "${tableName.value}"`
  const r = await invoke<{ csv: string }>('sqb.export_csv', [conn.connId, sql])
  await invoke('clipboard:write_text', r.csv)
  app.toast('CSV copied to clipboard', 'ok')
}
async function importCsv() {
  const res = await invoke<{ path: string; picked: boolean }>('sqb.pick_file')
  if (!res.picked) return
  try {
    await invoke('sqb.import_csv', [conn.connId, tableName.value, res.path])
    app.toast('CSV imported', 'ok')
  } catch (e: any) {
    app.setError('CSV import failed', e.message ?? 'Unknown error')
  }
  await loadInitial()
}

async function onCellEdit(payload: { row: any; col: string; value: any }) {
  const { row, col, value } = payload
  try {
    if (!pkCol.value) throw new Error('No primary key column found; cannot update by row.')
    await invoke('sqb.update_row', [conn.connId, tableName.value, { col: pkCol.value, value: row[pkCol.value] }, { [col]: value }])
    row[col] = value
    app.toast('Row updated', 'ok')
  } catch (e: any) {
    app.setError('Row update failed', e.message ?? 'Unknown error')
    await loadInitial()
  }
}

async function deleteRow(row: any) {
  try {
    if (!pkCol.value) throw new Error('No primary key column found; cannot delete by row.')
    await invoke('sqb.delete_row', [conn.connId, tableName.value, { col: pkCol.value, value: row[pkCol.value] }])
    rows.value = rows.value.filter((r) => r !== row)
    total.value = Math.max(0, total.value - 1)
    app.toast('Row deleted', 'ok')
  } catch (e: any) {
    app.setError('Row delete failed', e.message ?? 'Unknown error')
  }
}

async function onRowAdd(values: Record<string, any>) {
  try {
    await invoke('sqb.insert_row', [conn.connId, tableName.value, values])
    app.toast('Row added', 'ok')
    showAdd.value = false
  } catch (e: any) {
    app.setError('Row add failed', e.message ?? 'Unknown error')
  }
  await loadInitial()
}

watch(() => ui.activeTable, async () => { searchTerm.value = ''; sortCol.value = null; sortDir.value = 'ASC'; rows.value = []; await loadInitial() })
watch(() => schema.objects, () => { if (conn.connId && tableName.value && !rows.value.length) loadInitial() })
onMounted(loadInitial)
</script>
