<template>
  <div class="split-left">
    <div class="card-head" style="background: var(--bg-1)">
      <h3><Icon name="database" :size="14" /> Database</h3>
      <button class="btn sm primary" @click="$emit('new-table')" :disabled="!conn.connId" title="New Table"><Icon name="table" :size="14" /> Table</button>
      <button class="btn icon ghost sm" @click="schema.refresh()" :disabled="!conn.connId" title="Refresh"><Icon name="refresh-cw" :size="14" /></button>
    </div>
    <div v-if="!conn.connId" class="empty" style="flex: 1">
      <p>No database open.</p>
    </div>
    <div v-else style="flex: 1; overflow-y: auto">
      <template v-for="type in ['table', 'view', 'index', 'trigger']" :key="type">
        <div class="nav-section" style="padding: 6px 12px; text-transform: capitalize">{{ type }}s</div>
        <div
          v-for="o in schema.grouped(type)"
          :key="o.name"
          class="list-item"
          :class="{ active: o.name === ui.activeTable }"
          style="cursor: pointer"
          @click="onSelect(o)"
        >
          <Icon :name="iconFor(type)" :size="14" class="muted" />
          <span style="font-family: var(--font-mono); font-size: 12px">{{ o.name }}</span>
          <span v-if="o.row_count != null" class="muted" style="font-size: 11px; margin-left: auto">{{ o.row_count }} rows</span>
        </div>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useConnectionsStore } from '../stores/connections'
import { useSchemaStore } from '../stores/schema'
import { useUiStore } from '../stores/ui'
import Icon from './Icon.vue'

const emit = defineEmits<{ (e: 'new-table'): void; (e: 'open-object', o: any): void }>()

const conn = useConnectionsStore()
const schema = useSchemaStore()
const ui = useUiStore()

const ICONS: Record<string, string> = {
  table: 'table',
  view: 'table-2',
  index: 'list-ordered',
  trigger: 'zap',
}
function iconFor(type: string) {
  return ICONS[type] ?? 'circle'
}

function onSelect(o: any) {
  if (o.type === 'table' || o.type === 'view') {
    ui.activeTable = o.name
    ui.tableTab = 'data'
  } else {
    emit('open-object', o)
  }
}
</script>
