import { defineStore } from 'pinia'
import { ref } from 'vue'
import { invoke } from '../ipc'
import { useAppStore } from './app'
import { useSchemaStore } from './schema'

export const useQueryStore = defineStore('query', () => {
  const sql = ref('')
  const defaultFor = (table: string) => (table ? `SELECT * FROM ${table};` : '')
  const isDefault = (s: string, table: string) => s === defaultFor(table) || s === ''
  const result = ref<any>(null)
  const error = ref('')
  const log = ref<{ ts: string; sql: string; rows?: number; ms?: number }[]>([])
  const running = ref(false)

  async function run(connId: string) {
    if (!sql.value.trim()) return
    running.value = true
    error.value = ''
    const trimmed = sql.value.trim().toUpperCase()
    const isSelect = trimmed.startsWith('SELECT') || trimmed.startsWith('WITH') || trimmed.startsWith('PRAGMA')
    const ts = new Date().toLocaleTimeString()
    const app = useAppStore()
    try {
      if (isSelect) {
        const r = await invoke<any>('sqb.query', [connId, sql.value, 1000])
        result.value = r
        log.value.unshift({ ts, sql: sql.value, rows: r.count, ms: r.duration_ms })
      } else {
        const r = await invoke<{ ok: boolean; duration_ms: number }>('sqb.execute', [connId, sql.value])
        log.value.unshift({ ts, sql: sql.value, ms: r.duration_ms })
        result.value = null
        // DDL (CREATE/ALTER/DROP/...) changed the schema — refresh the
        // outline so new tables/indexes appear without a manual refresh.
        await useSchemaStore().refresh()
      }
    } catch (e: any) {
      error.value = e.message
      log.value.unshift({ ts, sql: sql.value })
      app.setError('SQL execution failed', e.message ?? 'Unknown error')
    } finally {
      running.value = false
    }
  }

  function syncDefault(table: string) {
    if (isDefault(sql.value, lastTable)) sql.value = defaultFor(table)
    lastTable = table
  }
  let lastTable = ''

  return { sql, result, error, log, running, run, syncDefault }
})
