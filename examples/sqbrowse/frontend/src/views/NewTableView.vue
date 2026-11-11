<template>
  <div style="display: flex; flex-direction: column; height: 100%">
    <div class="nt-head">
      <span class="nt-title">New Table</span>
      <div class="nt-tabs" style="margin-left: 14px">
        <button class="btn sm ghost" :class="{ primary: mode === 'editor' }" @click="mode = 'editor'"><Icon name="table" :size="14" /> Editor</button>
        <button class="btn sm ghost" :class="{ primary: mode === 'ddl' }" @click="mode = 'ddl'"><Icon name="code" :size="14" /> DDL Script</button>
      </div>
      <div style="flex: 1"></div>
      <button class="btn sm ghost" @click="$emit('cancel')"><Icon name="x" :size="14" /> Cancel</button>
      <button class="btn sm primary" v-if="mode === 'editor'" @click="submit" :disabled="!valid"><Icon name="check" :size="14" /> Create Table</button>
      <button class="btn sm primary" v-else @click="runDdl" :disabled="!ddl.trim() || busy"><Icon name="play" :size="14" /> Run Script</button>
    </div>

    <!-- Visual editor -->
    <div v-if="mode === 'editor'" class="nt-body">
      <label class="nt-label">Table name</label>
      <input
        class="input sm"
        v-model="name"
        placeholder="e.g. users"
        style="width: 280px; margin-bottom: 18px"
        @keyup.enter="addCol"
      />

      <div style="display: flex; align-items: center; margin-bottom: 8px">
        <span class="nt-label" style="margin: 0">Columns</span>
        <div style="flex: 1"></div>
        <button class="btn sm ghost" @click="addCol"><Icon name="plus" :size="14" /> Add column</button>
      </div>

      <table class="data-table" style="max-width: 640px">
        <thead>
          <tr><th>Column</th><th>Type</th><th style="text-align:center">PK</th><th style="text-align:center">Not Null</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="(c, i) in cols" :key="i">
            <td><input class="input sm" v-model="c.name" placeholder="name" style="width: 160px" /></td>
            <td>
              <select class="input sm" v-model="c.type" style="width: 110px">
                <option v-for="t in types" :key="t" :value="t">{{ t }}</option>
              </select>
            </td>
            <td style="text-align: center">
              <input type="checkbox" v-model="c.pk" @change="onPk(c)" />
            </td>
            <td style="text-align: center">
              <input type="checkbox" v-model="c.notnull" :disabled="c.pk" />
            </td>
            <td>
              <button class="btn sm ghost" @click="cols.splice(i, 1)" :disabled="cols.length === 1" title="Remove column"><Icon name="trash-2" :size="14" /></button>
            </td>
          </tr>
        </tbody>
      </table>

      <p v-if="!valid" class="muted" style="font-size: 12px; margin-top: 12px">
        Every column needs a name, and exactly one primary key is required.
      </p>
    </div>

    <!-- DDL script -->
    <div v-else class="nt-body ddl-body">
      <p class="muted" style="font-size: 12px; margin-top: 0; margin-bottom: 10px">
        Paste a <code>CREATE TABLE</code> (or any DDL) statement. It runs against the
        current database exactly as written.
      </p>
      <SqlEditor v-model="ddl" :height="'calc(100% - 70px)'" style="display: block" />
      <p v-if="error" class="err" style="font-size: 12px; margin-top: 8px">{{ error }}</p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { invoke } from '../ipc'
import SqlEditor from '../components/SqlEditor.vue'
import { useAppStore } from '../stores/app'
import { useConnectionsStore } from '../stores/connections'

const emit = defineEmits<{
  (e: 'submit', payload: { name: string; columns: { name: string; type: string; pk: boolean; notnull: boolean }[] }): void
  (e: 'cancel'): void
  (e: 'created', name: string): void
}>()

const app = useAppStore()
const conn = useConnectionsStore()

const types = ['INTEGER', 'TEXT', 'REAL', 'BLOB', 'NUMERIC']
const mode = ref<'editor' | 'ddl'>('editor')
const name = ref('')
const cols = ref<{ name: string; type: string; pk: boolean; notnull: boolean }[]>([
  { name: 'id', type: 'INTEGER', pk: true, notnull: true },
])
const ddl = ref('')
const busy = ref(false)
const error = ref('')

function addCol() {
  cols.value.push({ name: '', type: 'TEXT', pk: false, notnull: false })
}
function onPk(c: { pk: boolean }) {
  if (c.pk) cols.value.forEach((x) => { if (x !== c) x.pk = false })
}

const valid = computed(() => {
  const named = cols.value.filter((c) => c.name.trim())
  if (!name.value.trim() || named.length !== cols.value.length) return false
  return cols.value.filter((c) => c.pk).length === 1
})

function submit() {
  if (!valid.value) return
  emit('submit', {
    name: name.value.trim(),
    columns: cols.value.map((c) => ({ name: c.name.trim(), type: c.type, pk: c.pk, notnull: c.notnull })),
  })
}

async function runDdl() {
  if (!ddl.value.trim() || busy.value) return
  busy.value = true
  error.value = ''
  try {
    await invoke('sqb.execute', [conn.connId, ddl.value])
    app.toast('Script executed', 'ok')
    const m = ddl.value.match(/create\s+table\s+(?:if\s+not\s+exists\s+)?(?:["`]?(\w+)["`]?)/i)
    const tbl = m ? m[1] : ''
    emit('created', tbl)
  } catch (e: any) {
    error.value = e.message ?? 'Execution failed'
    app.setError('Script failed', error.value)
  } finally { busy.value = false }
}
</script>

<style scoped>
.nt-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 14px;
  background: var(--bg-2);
  border-bottom: 1px solid var(--border);
}
.nt-title { font-size: 13px; color: var(--accent); }
.nt-tabs { display: flex; gap: 4px; }
.nt-body { padding: 16px 18px; overflow-y: auto; flex: 1; }
.ddl-body { display: flex; flex-direction: column; }
.nt-label { font-size: 11px; color: var(--text-1); display: block; margin-bottom: 4px; }
.err { color: var(--danger, #e5484d); }
</style>
