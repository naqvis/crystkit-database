<template>
  <div class="table-wrap" style="flex: 1; overflow: auto">
    <table class="data-table" v-if="columns.length">
      <thead>
        <tr>
          <th
            v-for="col in columns"
            :key="col"
            :class="{ sortable: sortable, sorted: sortable && activeSort?.col === col }"
            @click="sortable && $emit('sort', col)"
          >
            <span>{{ col }}</span>
            <Icon
              v-if="sortable && activeSort?.col === col"
              :name="activeSort.dir === 'DESC' ? 'arrow-down' : 'arrow-up'"
              :size="12"
            />
          </th>
          <th v-if="editable" style="width: 64px">·</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(row, i) in rows" :key="i">
          <td
            v-for="col in columns"
            :key="col"
            :class="{ editable: editable }"
            :title="editable ? 'Click to edit' : String(row[col] ?? '')"
            @click="editable && startEdit(row, col, $event)"
          >
            <input
              v-if="edit && edit.row === row && edit.col === col"
              class="cell-input"
              :value="edit.draft"
              ref="cellInput"
              @keyup.enter="commitEdit"
              @keyup.esc="cancelEdit"
              @blur="commitEdit"
            />
            <span v-else>{{ row[col] ?? 'NULL' }}</span>
          </td>
          <td v-if="editable">
            <button class="btn sm ghost" @click="$emit('row-delete', row)" title="Delete row"><Icon name="trash-2" :size="14" /></button>
          </td>
        </tr>
        <tr v-if="editable && showAdd" class="add-row">
          <td v-for="col in columns" :key="col">
            <input
              class="cell-input"
              v-model="draft[col]"
              :placeholder="col === pkCol ? 'auto' : ''"
              @keyup.enter="submitAdd"
            />
          </td>
          <td>
            <button class="btn sm primary" @click="submitAdd" title="Save row"><Icon name="check" :size="14" /></button>
            <button class="btn sm ghost" @click="$emit('add-cancel')" title="Cancel"><Icon name="x" :size="14" /></button>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<script setup lang="ts">
import { nextTick, ref } from 'vue'
import Icon from './Icon.vue'

const props = defineProps<{ columns: string[]; rows: any[]; editable?: boolean; pkCol?: string; showAdd?: boolean; sortable?: boolean; activeSort?: { col: string; dir: 'ASC' | 'DESC' } | null }>()
const emit = defineEmits<{
  (e: 'cell-edit', payload: { row: any; col: string; value: any }): void
  (e: 'row-delete', row: any): void
  (e: 'row-add', values: Record<string, any>): void
  (e: 'add-cancel'): void
  (e: 'sort', col: string): void
}>()

const edit = ref<{ row: any; col: string; draft: string } | null>(null)
const cellInput = ref<HTMLInputElement | null>(null)
const draft = ref<Record<string, any>>({})

function startEdit(row: any, col: string, ev: MouseEvent) {
  const target = ev.currentTarget as HTMLElement
  edit.value = { row, col, draft: row[col] == null ? '' : String(row[col]) }
  nextTick(() => {
    cellInput.value?.focus()
    cellInput.value?.select()
    void target
  })
}

function commitEdit() {
  if (!edit.value) return
  const { row, col, draft } = edit.value
  edit.value = null
  const current = row[col] == null ? '' : String(row[col])
  if (draft === current) return
  const original = row[col]
  const value: any = typeof original === 'number' && draft.trim() !== '' && !isNaN(Number(draft))
    ? Number(draft)
    : draft === '' && original == null
      ? null
      : draft
  emit('cell-edit', { row, col, value })
}

function cancelEdit() {
  edit.value = null
}

function submitAdd() {
  const values: Record<string, any> = {}
  for (const c of props.columns) {
    if (c === 'rowid') continue
    const v = draft.value[c]
    values[c] = v === '' || v == null ? null : v
  }
  emit('row-add', values)
}
</script>

<style scoped>
.editable {
  cursor: text;
}
.cell-input {
  width: 100%;
  box-sizing: border-box;
  font: inherit;
  padding: 2px 4px;
  border: 1px solid var(--accent);
  border-radius: 3px;
  background: var(--bg-0);
  color: var(--text-0);
}
.sortable { cursor: pointer; user-select: none; white-space: nowrap; }
.sortable:hover { color: var(--accent); }
.sorted { color: var(--accent); }
.sorted :deep(.icon) { vertical-align: middle; margin-left: 4px; }
</style>
