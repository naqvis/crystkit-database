<template>
  <div class="topbar">
    <span class="topbar-title"><Icon name="database" :size="16" /> SQBrowse</span>

    <!-- No database open: only entry points -->
    <template v-if="!conn.connId">
      <button class="btn sm primary" @click="conn.pickAndOpen()"><Icon name="folder-open" :size="14" /> Open DB…</button>
      <button class="btn sm ghost" @click="newDatabase()"><Icon name="file-plus" :size="14" /> New DB…</button>
    </template>

    <!-- New (unsaved) database in progress: finish or cancel the operation -->
    <template v-else-if="conn.connId && !conn.hasFile">
      <span class="pill warn" style="font-size: 11px"><Icon name="circle-alert" :size="12" /> Unsaved database</span>
      <button class="btn sm primary" @click="saveAs()"><Icon name="save" :size="14" /> Save As…</button>
      <button class="btn sm ghost" @click="cancelNew()"><Icon name="x" :size="14" /> Cancel</button>
    </template>

    <!-- Existing saved database open -->
    <template v-else>
      <button class="btn sm ghost" @click="conn.pickAndOpen()"><Icon name="folder-open" :size="14" /> Open DB…</button>
      <button class="btn sm ghost" @click="newDatabase()"><Icon name="file-plus" :size="14" /> New DB…</button>
      <button class="btn sm ghost" @click="conn.close()" :disabled="busy"><Icon name="x-circle" :size="14" /> Close</button>
      <button class="btn sm ghost" @click="vacuum()" :disabled="busy"><Icon name="minimize-2" :size="14" /> Compact</button>
    </template>

    <div style="flex: 1"></div>
    <span v-if="conn.currentPath" class="pill accent" style="font-size: 10px">{{ conn.currentPath }}</span>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { useConnectionsStore } from '../stores/connections'
import { useSchemaStore } from '../stores/schema'
import { useAppStore } from '../stores/app'
import { invoke } from '../ipc'
import Icon from './Icon.vue'
const conn = useConnectionsStore()
const schema = useSchemaStore()
const app = useAppStore()
const busy = ref(false)

async function vacuum() {
  if (!conn.connId) return
  busy.value = true
  try {
    await invoke('sqb.vacuum', conn.connId)
  } catch (e: any) {
    app.setError('Compact failed', e.message ?? String(e))
  } finally {
    busy.value = false
  }
}

async function newDatabase() {
  busy.value = true
  try {
    await conn.createEmpty()
    schema.refresh()
  } catch (e: any) {
    app.setError('Create failed', e.message ?? String(e))
  } finally {
    busy.value = false
  }
}

async function saveAs() {
  const path = await invoke<string | null>('dialog.save_file', {
    title: 'Save Database As',
    default_name: 'my.db',
    filters: [{ name: 'SQLite Databases', extensions: ['db', 'sqlite', 'sqlite3'] }],
  })
  if (!path) return
  busy.value = true
  try {
    await conn.saveAs(path)
    schema.refresh()
  } catch (e: any) {
    app.setError('Save failed', e.message ?? String(e))
  } finally {
    busy.value = false
  }
}

// Cancel the in-progress new-database operation: discard the unsaved DB.
async function cancelNew() {
  busy.value = true
  try {
    await conn.close()
    schema.refresh()
  } catch (e: any) {
    app.setError('Cancel failed', e.message ?? String(e))
  } finally {
    busy.value = false
  }
}
</script>
