<template>
  <div style="display: flex; flex-direction: column; height: 100%">
    <div class="tbl-head">
      <span class="tbl-name">{{ obj.name }}</span>
      <span class="pill muted" style="text-transform: capitalize">{{ obj.type }}</span>
      <div style="flex: 1"></div>
      <button class="btn sm ghost" @click="ui.activeTable = ''" title="Back to database"><Icon name="arrow-left" :size="14" /></button>
    </div>

    <div class="obj-tabs">
      <button class="btn sm ghost" :class="{ primary: tab === 'ddl' }" @click="tab = 'ddl'">DDL</button>
      <button v-if="obj.type === 'view'" class="btn sm ghost" :class="{ primary: tab === 'data' }" @click="tab = 'data'">Data</button>
    </div>

    <div style="flex: 1; overflow: auto">
      <div v-if="tab === 'ddl'" style="padding: 12px">
        <SqlView v-if="obj.sql" :code="obj.sql" />
        <p v-else class="muted">No DDL available.</p>
      </div>
      <BrowseData v-else-if="tab === 'data'" :single-table="obj.name" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import SqlView from '../components/SqlView.vue'
import BrowseData from './BrowseData.vue'
import Icon from '../components/Icon.vue'
import { useUiStore } from '../stores/ui'

defineProps<{ obj: any }>()
const ui = useUiStore()
const tab = ref<'ddl' | 'data'>('ddl')
</script>

<style scoped>
.obj-tabs {
  display: flex;
  gap: 4px;
  padding: 0 12px;
  border-bottom: 1px solid var(--border);
}
</style>
