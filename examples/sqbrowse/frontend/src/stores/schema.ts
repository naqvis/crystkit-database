import { defineStore } from 'pinia'
import { ref } from 'vue'
import { invoke } from '../ipc'
import { useConnectionsStore } from './connections'

export const useSchemaStore = defineStore('schema', () => {
  const objects = ref<any[]>([])

  async function refresh() {
    const conn = useConnectionsStore()
    if (!conn.connId) { objects.value = []; return }
    objects.value = await invoke<any[]>('sqb.schema', conn.connId)
  }

  function grouped(type: string) {
    return objects.value.filter((o) => o.type === type)
  }

  return { objects, refresh, grouped }
})
