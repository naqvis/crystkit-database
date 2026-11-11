import { defineStore } from 'pinia'
import { ref } from 'vue'

export const useUiStore = defineStore('ui', () => {
  const activeTab = ref<'browse' | 'sql' | 'schema' | 'pragmas' | 'graph'>('browse')
  const activeTable = ref('')
  const tableTab = ref<'structure' | 'data' | 'ddl'>('structure')
  return { activeTab, activeTable, tableTab }
})
