<template>
  <component :is="icon" :size="size" :stroke-width="strokeWidth" class="icon" />
</template>

<script setup lang="ts">
import {
  ArrowLeft, BarChart3, Check, CircleAlert, ClipboardCopy, Code, Database,
  Download, File, FilePlus, FolderOpen, GitBranch, ListOrdered, Minimize2, Pencil,
  Play, Plus, RefreshCw, Save, SlidersHorizontal, Table, Table2, Terminal,
  Trash2, Upload, X, XCircle, Zap, CircleHelp,
} from 'lucide-vue-next'

// Explicit, tree-shaken icon set. Only the icons listed here are bundled.
const ICONS: Record<string, any> = {
  'arrow-left': ArrowLeft,
  'bar-chart-3': BarChart3,
  'check': Check,
  'circle-alert': CircleAlert,
  'clipboard-copy': ClipboardCopy,
  'code': Code,
  'database': Database,
  'download': Download,
  'file': File,
  'file-plus': FilePlus,
  'folder-open': FolderOpen,
  'git-branch': GitBranch,
  'list-ordered': ListOrdered,
  'minimize-2': Minimize2,
  'pencil': Pencil,
  'play': Play,
  'plus': Plus,
  'refresh-cw': RefreshCw,
  'save': Save,
  'sliders-horizontal': SlidersHorizontal,
  'table': Table,
  'table-2': Table2,
  'terminal': Terminal,
  'trash-2': Trash2,
  'upload': Upload,
  'x': X,
  'x-circle': XCircle,
  'zap': Zap,
}

const props = withDefaults(
  defineProps<{
    name: string
    size?: number | string
    strokeWidth?: number | string
  }>(),
  { size: 16, strokeWidth: 2 },
)

const icon = ICONS[props.name] ?? CircleHelp
</script>

<style scoped>
.icon {
  display: inline-block;
  vertical-align: middle;
  flex: none;
}
</style>
