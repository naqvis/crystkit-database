<template>
  <div style="padding: 12px; overflow-y: auto; height: 100%">
    <div class="kv">
      <div class="row" v-for="p in pragmas" :key="p.name">
        <span class="k">{{ p.name }}</span>
        <span>
          <input class="input" :value="p.value ?? ''" @change="setPragma(p.name, ($event.target as HTMLInputElement).value)" style="width: 200px" />
        </span>
      </div>
    </div>
    <div style="margin-top: 16px; display: flex; gap: 8px">
      <button class="btn sm ghost" @click="backup">Backup…</button>
      <button class="btn sm ghost" @click="restore">Restore…</button>
      <button class="btn sm ghost" @click="attach">Attach DB…</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'
import { invoke } from '../ipc'
import { useConnectionsStore } from '../stores/connections'
import { useAppStore } from '../stores/app'

const conn = useConnectionsStore()
const app = useAppStore()
const pragmas = ref<{ name: string; value: string | null }[]>([])

async function load() {
  if (conn.connId) pragmas.value = await invoke('sqb.pragmas', conn.connId)
}
async function setPragma(name: string, value: string) {
  await invoke('sqb.set_pragma', [conn.connId, name, value])
  await load()
}
async function backup() {
  const res = await invoke<{ path: string; picked: boolean }>('sqb.pick_file')
  if (!res.picked) return
  try { await invoke('sqb.backup', [conn.connId, res.path]); app.toast('Backed up', 'ok') }
  catch (e: any) { app.setError('Backup failed', e.message ?? 'Unknown error') }
}
async function restore() {
  const res = await invoke<{ path: string; picked: boolean }>('sqb.pick_file')
  if (!res.picked) return
  try { await invoke('sqb.restore', [conn.connId, res.path]); app.toast('Restored', 'ok') }
  catch (e: any) { app.setError('Restore failed', e.message ?? 'Unknown error') }
}
async function attach() {
  const res = await invoke<{ path: string; picked: boolean }>('sqb.pick_file')
  if (!res.picked) return
  try { await invoke('sqb.attach', [conn.connId, res.path, 'attached']); app.toast('Attached', 'ok') }
  catch (e: any) { app.setError('Attach failed', e.message ?? 'Unknown error') }
}

watch(() => conn.connId, load)
onMounted(load)
</script>
