import { defineStore } from 'pinia'
import { ref } from 'vue'
import { invoke } from '../ipc'

// The recent-databases list is owned entirely by the frontend and persisted
// through the separate Store plugin (`store.get` / `store.set`). The
// backend keeps only a session mirror via `sqb.recent` for convenience.
const STORE_NS = 'sqbrowse'
const RECENT_KEY = 'recent'

function uniqRecents(list: { name: string; path: string }[]): { name: string; path: string }[] {
  const seen = new Set<string>()
  const out: { name: string; path: string }[] = []
  for (const r of list) {
    if (!r?.path || seen.has(r.path)) continue
    seen.add(r.path)
    out.push(r)
  }
  return out.slice(0, 20)
}

export const useConnectionsStore = defineStore('connections', () => {
  const connId = ref('')
  const currentPath = ref('')
  const fullPath = ref('')
  const hasFile = ref(false)
  const recent = ref<{ name: string; path: string }[]>([])

  // Persist the current recents through the Store plugin so they survive restarts.
  async function persistRecent() {
    try {
      await invoke('store.set', [STORE_NS, RECENT_KEY, recent.value])
    } catch { /* storage unavailable; non-fatal */ }
  }

  // Seed `recent` from the persisted store at boot — no backend round-trip
  // needed, the Store plugin is the source of truth across restarts.
  async function loadPersisted() {
    try {
      const saved = await invoke<{ name: string; path: string }[] | null>(
        'store.get', [STORE_NS, RECENT_KEY],
      )
      if (saved?.length) recent.value = uniqRecents(saved)
    } catch { /* no stored recents yet */ }
  }

  // Mirror a freshly opened/saved database into the recents list and persist.
  // Owned by the frontend so pre-restart recents are never lost.
  function pushRecent(name: string, path: string) {
    recent.value = uniqRecents([{ name, path }, ...recent.value])
    persistRecent()
  }

  async function clearRecent() {
    recent.value = []
    try {
      await invoke('store.delete', [STORE_NS, RECENT_KEY])
    } catch { /* non-fatal */ }
  }

  async function open(path: string) {
    const id = `conn-${Date.now()}`
    const res = await invoke<{ conn_id: string; path: string; ok: boolean }>(
      'sqb.open', [id, path],
    )
    if (res.ok) {
      connId.value = res.conn_id
      fullPath.value = res.path
      currentPath.value = res.path.split('/').pop() ?? res.path
      hasFile.value = true
      pushRecent(res.path.split('/').pop() ?? res.path, res.path)
    }
  }

  async function create(path: string) {
    const id = `conn-${Date.now()}`
    const res = await invoke<{ conn_id: string; path: string; ok: boolean }>(
      'sqb.create', [id, path],
    )
    if (res.ok) {
      connId.value = res.conn_id
      fullPath.value = res.path
      currentPath.value = res.path.split('/').pop() ?? res.path
      hasFile.value = true
      pushRecent(res.path.split('/').pop() ?? res.path, res.path)
    }
  }

  async function createEmpty() {
    const id = `conn-${Date.now()}`
    const res = await invoke<{ conn_id: string; path: string; memory: boolean; ok: boolean }>(
      'sqb.create_memory', id,
    )
    if (res.ok) {
      connId.value = res.conn_id
      fullPath.value = ''
      currentPath.value = 'untitled'
      hasFile.value = false
      // In-memory DBs have no path and are not worth remembering.
    }
  }

  async function saveAs(path: string) {
    const res = await invoke<{ conn_id: string; path: string; ok: boolean }>(
      'sqb.save_as', [connId.value, path],
    )
    if (res.ok) {
      fullPath.value = res.path
      currentPath.value = res.path.split('/').pop() ?? res.path
      hasFile.value = true
      pushRecent(res.path.split('/').pop() ?? res.path, res.path)
    }
  }

  async function pickAndOpen() {
    const res = await invoke<{ path: string; picked: boolean }>('sqb.pick_file')
    if (res.picked) await open(res.path)
  }

  async function close() {
    if (!connId.value) return
    await invoke('sqb.close', connId.value)
    connId.value = ''
    currentPath.value = ''
    fullPath.value = ''
    hasFile.value = false
  }

  return {
    connId, currentPath, fullPath, hasFile, recent,
    open, create, createEmpty, saveAs, pickAndOpen, close,
    loadPersisted, clearRecent,
  }
})
