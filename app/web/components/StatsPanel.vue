<script setup lang="ts">
import type { ActivityDay, Summary } from '~/composables/useReports'

const props = defineProps<{
  summary: Summary | null
  activity: ActivityDay[]
  updatedAt: Date | null
  stale: boolean
}>()

const cards = computed(() => [
  { label: 'Total', value: props.summary?.total, tone: 'text-slate-900' },
  { label: 'Todo', value: props.summary?.todo, tone: 'text-amber-600' },
  { label: 'Doing', value: props.summary?.doing, tone: 'text-sky-600' },
  { label: 'Done', value: props.summary?.done, tone: 'text-emerald-600' }
])

const completion = computed(() => {
  const s = props.summary
  return s && s.total > 0 ? Math.round((s.done / s.total) * 100) : 0
})

const peak = computed(() => Math.max(1, ...props.activity.map(d => d.created)))

function weekday(day: string) {
  return new Date(`${day}T00:00:00`).toLocaleDateString(undefined, { weekday: 'short' })
}
</script>

<template>
  <section class="space-y-3 rounded border border-slate-200 bg-white p-4" data-testid="stats-panel">
    <div class="grid grid-cols-4 gap-2">
      <div v-for="card in cards" :key="card.label" class="rounded bg-slate-50 px-3 py-2 text-center">
        <div class="text-xs uppercase tracking-wide text-slate-500">{{ card.label }}</div>
        <div class="text-xl font-semibold" :class="card.tone" :data-testid="`stat-${card.label.toLowerCase()}`">
          {{ card.value ?? '–' }}
        </div>
      </div>
    </div>
    <div>
      <div class="mb-1 flex justify-between text-xs text-slate-500">
        <span>Completion</span>
        <span>{{ completion }}%</span>
      </div>
      <div class="h-2 overflow-hidden rounded bg-slate-100">
        <div class="h-full bg-emerald-500 transition-all" :style="{ width: `${completion}%` }" />
      </div>
    </div>
    <div>
      <div class="mb-1 text-xs text-slate-500">Created in the last 7 days</div>
      <div class="flex h-16 items-end gap-1" data-testid="activity">
        <div v-for="d in activity" :key="d.day" class="flex flex-1 flex-col items-center gap-1">
          <div class="w-full rounded-t bg-sky-400" :style="{ height: `${(d.created / peak) * 48}px` }" :title="`${d.day}: ${d.created}`" />
          <span class="text-[10px] text-slate-400">{{ weekday(d.day) }}</span>
        </div>
      </div>
    </div>
    <p class="text-right text-[11px]" :class="stale ? 'text-amber-600' : 'text-slate-400'">
      <template v-if="stale">report service unreachable — showing last known values</template>
      <template v-else-if="updatedAt">updated {{ updatedAt.toLocaleTimeString() }} · refreshes every 30s</template>
    </p>
  </section>
</template>
