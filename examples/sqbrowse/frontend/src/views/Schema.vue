<template>
  <div style="height: 100%; overflow-y: auto; padding: 12px">
    <div v-if="!conn.connId" class="empty">
      <p>Open a database to view its schema.</p>
    </div>
    <div v-else>
      <p class="muted" style="font-size: 12px; margin: 0 0 10px">
        Select a table from the outline to edit its structure, browse its data, or view its DDL.
      </p>
      <div v-for="type in ['table', 'view', 'index', 'trigger']" :key="type">
        <div class="nav-section" style="padding: 10px 4px 6px; text-transform: capitalize">{{ type }}s</div>
        <div v-for="o in schema.grouped(type)" :key="o.name" class="schema-card">
          <div class="schema-head">
            <span class="schema-name">{{ o.name }}</span>
            <span v-if="o.row_count != null" class="pill muted">{{ o.row_count }} rows</span>
            <div style="flex: 1"></div>
            <button v-if="o.type === 'table' || o.type === 'view'" class="btn sm primary" @click="openTable(o.name)">Open</button>
          </div>
          <table v-if="o.columns && o.columns.length" class="data-table" style="margin-top: 6px">
            <thead>
              <tr>
                <th style="width: 28px"></th>
                <th>Column</th>
                <th>Type</th>
                <th>Constraints</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="c in o.columns" :key="c.name">
                <td class="muted" style="text-align: center">{{ c.pk ? 'PK' : '' }}</td>
                <td style="font-family: var(--font-mono)">{{ c.name }}</td>
                <td style="font-family: var(--font-mono)">{{ c.type }}</td>
                <td class="muted">
                  <span v-if="c.pk">PRIMARY KEY</span>
                  <span v-if="c.notnull && !c.pk">NOT NULL</span>
                </td>
              </tr>
            </tbody>
          </table>
          <div v-if="o.sql" style="margin-top: 10px">
            <div class="nav-section" style="padding: 2px 0 4px">DDL</div>
            <SqlView :code="o.sql" />
          </div>
        </div>
      </div>
      <p v-if="!schema.objects.length" class="muted" style="padding: 12px 4px">No objects in this database yet.</p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, watch } from 'vue'
import { useConnectionsStore } from '../stores/connections'
import { useSchemaStore } from '../stores/schema'
import { useUiStore } from '../stores/ui'
import SqlView from '../components/SqlView.vue'

const conn = useConnectionsStore()
const schema = useSchemaStore()
const ui = useUiStore()

function openTable(name: string) {
  ui.activeTable = name
  ui.tableTab = 'structure'
}

watch(() => conn.connId, () => schema.refresh())
onMounted(() => schema.refresh())
</script>
