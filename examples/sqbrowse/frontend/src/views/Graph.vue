<template>
  <div style="padding: 12px; height: 100%; overflow-y: auto">
    <div class="controls" style="display: flex; gap: 10px; flex-wrap: wrap; align-items: flex-end; margin-bottom: 12px">
      <div class="ctl" style="display: flex; flex-direction: column; gap: 4px">
        <label style="font-size: 10.5px; color: var(--text-1)">Source</label>
        <select class="input" v-model="source" @change="onSourceChange" style="width: 180px">
          <option value="">— select table —</option>
          <option v-for="t in tables" :key="t.name" :value="t.name">{{ t.name }}</option>
        </select>
      </div>
      <div class="ctl" style="display: flex; flex-direction: column; gap: 4px">
        <label style="font-size: 10.5px; color: var(--text-1)">X (category)</label>
        <select class="input" v-model="xCol" style="width: 160px">
          <option value="">— column —</option>
          <option v-for="c in columns" :key="c" :value="c">{{ c }}</option>
        </select>
      </div>
      <div class="ctl" style="display: flex; flex-direction: column; gap: 4px">
        <label style="font-size: 10.5px; color: var(--text-1)">Y (value)</label>
        <select class="input" v-model="yCol" style="width: 160px">
          <option value="">— column —</option>
          <option v-for="c in columns" :key="c" :value="c">{{ c }}</option>
        </select>
      </div>
      <div class="ctl" style="display: flex; flex-direction: column; gap: 4px">
        <label style="font-size: 10.5px; color: var(--text-1)">Aggregation</label>
        <select class="input" v-model="agg" style="width: 120px">
          <option>COUNT</option><option>SUM</option><option>AVG</option>
        </select>
      </div>
      <button class="btn sm primary" @click="render">↻ Render</button>
    </div>
    <div v-if="!source" class="muted" style="padding: 20px 0">Pick a table to chart.</div>
    <canvas v-else ref="canvas" style="width: 100%; height: 360px"></canvas>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, watch, nextTick } from 'vue'
import { invoke } from '../ipc'
import { useConnectionsStore } from '../stores/connections'
import { useSchemaStore } from '../stores/schema'
import { useAppStore } from '../stores/app'
import Chart from 'chart.js/auto'

const conn = useConnectionsStore()
const schema = useSchemaStore()
const app = useAppStore()
const source = ref('')
const xCol = ref('')
const yCol = ref('')
const agg = ref('COUNT')
const canvas = ref<HTMLCanvasElement | null>(null)
let chart: Chart | null = null

const tables = computed(() => schema.objects.filter((o) => o.type === 'table' || o.type === 'view'))
const columns = computed(() => {
  const t = tables.value.find((o) => o.name === source.value)
  return (t?.columns ?? []).map((c: any) => c.name)
})

function onSourceChange() {
  xCol.value = ''
  yCol.value = ''
}

async function render() {
  if (!conn.connId || !source.value || !xCol.value || !yCol.value) return
  try {
    const data = await invoke<{ labels: string[]; values: number[] }>(
      'sqb.graph_data', [conn.connId, source.value, xCol.value, yCol.value, agg.value])
    await nextTick()
    if (!canvas.value) return
    chart?.destroy()
    chart = new Chart(canvas.value, {
      type: 'bar',
      data: { labels: data.labels, datasets: [{ label: `${agg.value}(${yCol.value})`, data: data.values, backgroundColor: '#2563eb' }] },
      options: { responsive: true, maintainAspectRatio: false },
    })
  } catch (e: any) {
    app.setError('Graph failed', e.message ?? 'Unknown error')
  }
}

onMounted(() => { if (conn.connId) schema.refresh() })
watch(() => conn.connId, () => { source.value = ''; xCol.value = ''; yCol.value = ''; chart?.destroy(); chart = null })
</script>
