<template>
  <div class="modal-overlay" @click.self="$emit('cancel')">
    <div class="modal-box">
      <div class="modal-head">
        <span>{{ title }}</span>
        <button class="btn sm ghost" @click="$emit('cancel')">✕</button>
      </div>
      <div class="modal-body">
        <p v-if="message" class="muted" style="margin: 0 0 10px; font-size: 12px">{{ message }}</p>
        <div v-for="(f, i) in fields" :key="i" class="modal-field">
          <label :for="'mf-' + i" style="font-size: 11px; display: block; margin-bottom: 2px">{{ f.label }}</label>
          <input
            v-if="f.type === 'text' || f.type === 'number'"
            :id="'mf-' + i"
            class="input sm"
            :type="f.type"
            v-model="values[i]"
            :placeholder="f.placeholder"
            style="width: 100%"
            @keyup.enter="submit"
          />
          <select v-else-if="f.type === 'select'" :id="'mf-' + i" class="input sm" v-model="values[i]" style="width: 100%">
            <option v-for="opt in (f.options || [])" :key="opt" :value="opt">{{ opt }}</option>
          </select>
          <label v-else-if="f.type === 'checkbox'" class="modal-check">
            <input type="checkbox" v-model="values[i]" /> {{ f.checkboxLabel || '' }}
          </label>
        </div>
      </div>
      <div class="modal-foot">
        <div style="flex: 1"></div>
        <button class="btn sm ghost" @click="$emit('cancel')">Cancel</button>
        <button class="btn sm primary" @click="submit" :disabled="!valid">{{ okLabel }}</button>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'

export interface ModalField {
  key: string
  label: string
  type?: 'text' | 'number' | 'select' | 'checkbox'
  placeholder?: string
  options?: string[]
  checkboxLabel?: string
  required?: boolean
}

const props = defineProps<{
  title: string
  message?: string
  fields: ModalField[]
  okLabel?: string
  initial?: Record<string, any>
}>()
const emit = defineEmits<{
  (e: 'submit', values: Record<string, any>): void
  (e: 'cancel'): void
}>()

const values = ref<Record<string, any>>(
  Object.fromEntries(props.fields.map((f) => [f.key, props.initial?.[f.key] ?? (f.type === 'checkbox' ? false : '')])),
)

const valid = computed(() => props.fields.every((f) => !f.required || String(values.value[f.key] ?? '').trim() !== ''))

function submit() {
  if (!valid.value) return
  emit('submit', { ...values.value })
}
</script>

<style scoped>
.modal-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 1000;
}
.modal-box {
  background: var(--bg-1);
  border: 1px solid var(--border);
  border-radius: 8px;
  width: 380px;
  max-width: 90vw;
  box-shadow: 0 10px 40px rgba(0, 0, 0, 0.4);
}
.modal-head {
  display: flex;
  align-items: center;
  padding: 10px 14px;
  border-bottom: 1px solid var(--border);
  font-size: 13px;
  font-weight: 600;
}
.modal-head .btn { margin-left: auto; }
.modal-body { padding: 14px; }
.modal-field { margin-bottom: 10px; }
.modal-check { font-size: 12px; display: flex; gap: 6px; align-items: center; }
.modal-foot {
  display: flex;
  gap: 8px;
  padding: 10px 14px;
  border-top: 1px solid var(--border);
}
</style>
