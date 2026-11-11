<template>
  <div ref="host" class="sql-view"></div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { EditorState } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { sql, SQLite } from '@codemirror/lang-sql'
import { oneDark } from '@codemirror/theme-one-dark'

const props = defineProps<{ code: string }>()
const host = ref<HTMLDivElement | null>(null)
let view: EditorView | null = null

function build() {
  if (!host.value) return
  view?.destroy()
  view = new EditorView({
    state: EditorState.create({
      doc: props.code,
      extensions: [
        EditorState.readOnly.of(true),
        EditorView.editable.of(false),
        sql({ dialect: SQLite, upperCaseKeywords: true }),
        oneDark,
        EditorView.theme({ '&': { background: 'transparent' }, '.cm-scroller': { fontFamily: 'var(--font-mono)' } }),
      ],
    }),
    parent: host.value,
  })
}

onMounted(build)
// Rebuild if the code changes (e.g. switching objects).
watch(() => props.code, () => build())
onBeforeUnmount(() => view?.destroy())
</script>

<style scoped>
.sql-view {
  min-height: 120px;
}
.sql-view :deep(.cm-editor) {
  background: transparent;
  font-size: 12px;
  min-height: 120px;
}
.sql-view :deep(.cm-gutters) {
  background: transparent;
  border: none;
}
</style>
