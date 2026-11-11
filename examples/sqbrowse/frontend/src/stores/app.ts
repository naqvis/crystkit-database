import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface Toast { id: number; message: string; kind: 'ok' | 'error' | 'info' }
export const useAppStore = defineStore('app', () => {
  const toasts = ref<Toast[]>([])
  const error = ref<{ title: string; detail: string } | null>(null)
  let n = 0
  function toast(message: string, kind: Toast['kind'] = 'info') {
    const id = ++n
    toasts.value.push({ id, message, kind })
    setTimeout(() => { toasts.value = toasts.value.filter((t) => t.id !== id) }, 3000)
  }
  function setError(title: string, detail: string) {
    error.value = { title, detail }
  }
  function clearError() {
    error.value = null
  }
  return { toasts, error, toast, setError, clearError }
})
