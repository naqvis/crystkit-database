<template>
  <div ref="host" class="sql-editor" style="flex: 1 1 auto; min-height: 0"></div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { EditorState, Compartment } from '@codemirror/state'
import { autocompletion, completionKeymap } from '@codemirror/autocomplete'
import { EditorView, keymap } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { sql, SQLite, schemaCompletionSource } from '@codemirror/lang-sql'
import { oneDark } from '@codemirror/theme-one-dark'
import type { SQLNamespace } from '@codemirror/lang-sql'

const props = withDefaults(
  defineProps<{
    modelValue: string
    tables?: string[]
    columns?: string[]
    height?: string
  }>(),
  { height: '160px' },
)
const emit = defineEmits<{ (e: 'update:modelValue', v: string): void }>()

const host = ref<HTMLDivElement | null>(null)
let view: EditorView | null = null
const lang = new Compartment()

function schema(): SQLNamespace | undefined {
  if (!props.tables?.length) return undefined
  const tables: Record<string, string[]> = {}
  for (const t of props.tables) tables[t] = props.columns ?? []
  return tables as SQLNamespace
}

function sqlExt() {
  const s = schema()
  const base = sql({ dialect: SQLite, schema: s, upperCaseKeywords: true })
  const auto = s
    ? autocompletion({
        override: [schemaCompletionSource({ dialect: SQLite, schema: s })],
        activateOnTyping: true,
      })
    : []
  return [base, auto]
}

function buildState(doc: string) {
  return EditorState.create({
    doc,
    extensions: [
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap, ...completionKeymap]),
      lang.of(sqlExt()),
      oneDark,
      EditorView.theme({ '&': { height: props.height }, '.cm-scroller': { overflow: 'auto' } }),
      EditorView.updateListener.of((u) => {
        if (u.docChanged) emit('update:modelValue', u.state.doc.toString())
      }),
    ],
  })
}

onMounted(() => {
  if (!host.value) return
  view = new EditorView({ state: buildState(props.modelValue), parent: host.value })
})

watch(
  () => props.modelValue,
  (v) => {
    if (!view) return
    const cur = view.state.doc.toString()
    if (v !== cur) view.dispatch({ changes: { from: 0, to: cur.length, insert: v } })
  },
)

watch(
  () => [props.tables, props.columns],
  () => {
    if (!view) return
    view.dispatch({ effects: lang.reconfigure(sqlExt()) })
  },
)

onBeforeUnmount(() => view?.destroy())
</script>

<style scoped>
.sql-editor :deep(.cm-editor) {
  height: v-bind(height);
  font-size: 12px;
  border: 1px solid var(--border);
  border-radius: 4px;
}
.sql-editor :deep(.cm-editor.cm-focused) {
  outline: none;
  border-color: var(--accent);
}
</style>
