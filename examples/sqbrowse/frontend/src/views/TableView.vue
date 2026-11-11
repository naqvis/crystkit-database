<template>
  <div style="display: flex; flex-direction: column; height: 100%">
    <div class="tbl-head">
      <input
        v-if="renaming"
        class="input sm"
        v-model="renameDraft"
        style="width: 200px; font-weight: 600"
        @keyup.enter="commitRename"
        @keyup.esc="renaming = false"
        ref="renameInput"
      />
      <span v-else class="tbl-name">{{ table }}</span>
      <span v-if="rowCount != null" class="pill muted">{{ rowCount }} rows</span>
      <div style="flex: 1"></div>
      <button v-if="renaming" class="btn sm primary" @click="commitRename" :disabled="!renameDraft.trim() || busy"><Icon name="check" :size="14" /> Save</button>
      <button v-if="renaming" class="btn sm ghost" @click="renaming = false"><Icon name="x" :size="14" /> Cancel</button>
      <button v-else class="btn sm ghost" @click="startRename" :disabled="busy" title="Rename table"><Icon name="pencil" :size="14" /> Rename</button>
      <button class="btn sm ghost" @click="ui.activeTable = ''" title="Back to database"><Icon name="arrow-left" :size="14" /></button>
    </div>

    <div class="tbl-tabs">
      <button class="btn sm ghost" :class="{ primary: ui.tableTab === 'structure' }" @click="ui.tableTab = 'structure'">Structure</button>
      <button class="btn sm ghost" :class="{ primary: ui.tableTab === 'data' }" @click="ui.tableTab = 'data'">Data</button>
      <button class="btn sm ghost" :class="{ primary: ui.tableTab === 'ddl' }" @click="ui.tableTab = 'ddl'">DDL</button>
    </div>

    <div style="flex: 1; overflow: auto">
      <!-- Structure -->
      <div v-if="ui.tableTab === 'structure'" style="padding: 12px">
        <table class="data-table">
          <thead>
            <tr><th>Column</th><th>Type</th><th style="text-align:center">PK</th><th style="text-align:center">Not Null</th><th></th></tr>
          </thead>
          <tbody>
            <tr v-for="c in columns" :key="c.name">
              <template v-if="editCol && editCol.name === c.name">
                <td><input class="input sm" v-model="editCol.draft.name" style="width: 130px" /></td>
                <td>
                  <select class="input sm" v-model="editCol.draft.type" style="width: 100px">
                    <option v-for="t in types" :key="t" :value="t">{{ t }}</option>
                  </select>
                </td>
                <td style="text-align:center"><input type="checkbox" v-model="editCol.draft.pk" @change="onPkEdit" :disabled="columns.length === 1" /></td>
                <td style="text-align:center"><input type="checkbox" v-model="editCol.draft.notnull" :disabled="editCol.draft.pk" /></td>
                <td>
                  <button class="btn sm primary" @click="saveCol(c)" :disabled="!editCol.draft.name.trim() || busy">Save</button>
                  <button class="btn sm ghost" @click="editCol = null">Cancel</button>
                </td>
              </template>
              <template v-else>
                <td style="font-family: var(--font-mono)">{{ c.name }}</td>
                <td style="font-family: var(--font-mono)">{{ c.type }}</td>
                <td class="muted" style="text-align:center">{{ c.pk ? 'PK' : '' }}</td>
                <td class="muted" style="text-align:center">{{ c.notnull && !c.pk ? '✓' : '' }}</td>
                <td>
                  <button class="btn sm ghost" @click="startEdit(c)" :disabled="busy"><Icon name="pencil" :size="14" /> Modify</button>
                  <button class="btn sm ghost" @click="$emit('drop-column', c.name)" :disabled="busy || c.pk" :title="c.pk ? 'Cannot drop PK column' : 'Drop column'"><Icon name="trash-2" :size="14" /></button>
                </td>
              </template>
            </tr>
          </tbody>
        </table>

        <div class="struct-actions">
          <button class="btn sm ghost" @click="showAdd = !showAdd" :disabled="busy"><Icon name="plus" :size="14" /> Add Column</button>
          <button class="btn sm ghost" @click="$emit('drop-table', table)" :disabled="busy"><Icon name="table-2" :size="14" /> Drop Table</button>
        </div>
        <div v-if="showAdd" class="add-col">
          <input class="input sm" v-model="newCol.name" placeholder="column name" style="width: 140px" />
          <select class="input sm" v-model="newCol.type" style="width: 110px">
            <option v-for="t in types" :key="t" :value="t">{{ t }}</option>
          </select>
          <button class="btn sm primary" @click="addColumn" :disabled="!newCol.name || busy">Add</button>
          <button class="btn sm ghost" @click="showAdd = false">Cancel</button>
        </div>

        <div class="nav-section" style="padding: 12px 0 6px">Indexes</div>
        <div v-if="indexes.length">
          <div v-for="ix in indexes" :key="ix.name" class="index-row">
            <span style="font-family: var(--font-mono); font-size: 12px">{{ ix.name }}</span>
            <span class="muted" style="font-size: 11px">{{ ix.unique ? 'UNIQUE ' : '' }}on ({{ ix.cols }})</span>
            <button class="btn sm ghost" @click="$emit('drop-index', ix.name)" :disabled="busy"><Icon name="trash-2" :size="14" /></button>
          </div>
        </div>
        <p v-else class="muted" style="font-size: 12px">No indexes.</p>

        <div class="add-col" style="margin-top: 8px">
          <input class="input sm" v-model="newIdx.name" placeholder="index name" style="width: 130px" />
          <input class="input sm" v-model="newIdx.cols" placeholder="col1, col2" style="width: 150px" />
          <label style="font-size: 11px; display: flex; gap: 4px; align-items: center">
            <input type="checkbox" v-model="newIdx.unique" /> UNIQUE
          </label>
          <button class="btn sm primary" @click="createIndex" :disabled="!newIdx.name || !newIdx.cols || busy"><Icon name="plus" :size="14" /> Create Index</button>
        </div>
      </div>

      <!-- Data -->
      <BrowseData v-else-if="ui.tableTab === 'data'" :single-table="table" />

      <!-- DDL -->
      <div v-else-if="ui.tableTab === 'ddl'" style="padding: 12px">
        <SqlView v-if="ddl" :code="ddl" />
        <p v-else class="muted">No DDL available.</p>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, nextTick } from 'vue'
import BrowseData from '../views/BrowseData.vue'
import SqlView from '../components/SqlView.vue'
import Icon from '../components/Icon.vue'
import { useUiStore } from '../stores/ui'

const props = defineProps<{
  table: string
  columns: any[]
  indexes: { name: string; cols: string; unique: boolean }[]
  rowCount?: number | null
  ddl?: string
  busy?: boolean
}>()
const emit = defineEmits<{
  (e: 'drop-table', t: string): void
  (e: 'add-column', payload: { name: string; type: string }): void
  (e: 'drop-column', col: string): void
  (e: 'edit-column', payload: { oldName: string; name: string; type: string; pk: boolean; notnull: boolean }): void
   (e: 'create-index', payload: { name: string; cols: string; unique: boolean }): void
  (e: 'drop-index', name: string): void
  (e: 'rename-table', payload: { oldName: string; newName: string }): void
}>()

const ui = useUiStore()

const renaming = ref(false)
const renameDraft = ref('')
const renameInput = ref<HTMLInputElement | null>(null)

function startRename() {
  renaming.value = true
  renameDraft.value = props.table
  nextTick(() => renameInput.value?.focus())
}
function commitRename() {
  const newName = renameDraft.value.trim()
  if (!newName || newName === props.table) { renaming.value = false; return }
  emit('rename-table', { oldName: props.table, newName })
  renaming.value = false
}

const types = ['TEXT', 'INTEGER', 'REAL', 'BLOB', 'NUMERIC']
const showAdd = ref(false)
const newCol = ref({ name: '', type: 'TEXT' })
const newIdx = ref({ name: '', cols: '', unique: false })
const editCol = ref<{ name: string; draft: { name: string; type: string; pk: boolean; notnull: boolean } } | null>(null)

function startEdit(c: any) {
  editCol.value = { name: c.name, draft: { name: c.name, type: c.type, pk: !!c.pk, notnull: !!c.notnull } }
}
function onPkEdit() {
  if (editCol.value?.draft.pk) editCol.value.draft.notnull = true
}
function saveCol(c: any) {
  if (!editCol.value) return
  const d = editCol.value.draft
  emit('edit-column', { oldName: c.name, name: d.name.trim(), type: d.type, pk: d.pk, notnull: d.notnull })
  editCol.value = null
}
function addColumn() {
  emit('add-column', { ...newCol.value })
  newCol.value = { name: '', type: 'TEXT' }
  showAdd.value = false
}
function createIndex() {
  emit('create-index', { ...newIdx.value })
  newIdx.value = { name: '', cols: '', unique: false }
}
</script>

<style scoped>
.tbl-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  background: var(--bg-2);
  border-bottom: 1px solid var(--border);
}
.tbl-name { font-family: var(--font-mono); font-size: 13px; color: var(--accent); }
.tbl-tabs {
  display: flex;
  gap: 4px;
  padding: 0 12px;
  border-bottom: 1px solid var(--border);
  background: var(--bg-1);
}
.struct-actions { display: flex; gap: 8px; margin-top: 12px; }
.add-col { display: flex; gap: 6px; align-items: center; flex-wrap: wrap; }
.index-row { display: flex; gap: 8px; align-items: center; padding: 3px 0; font-size: 12px; }
.index-row .muted { flex: 1; }
</style>
