<script setup lang="ts">
import type { Task, TaskInput } from '~/composables/useTasks'

const { tasks, busy, errorMsg, load, create, update, remove } = useTasks()
const { summary, activity, updatedAt, stale, refresh } = useReports()

type Filter = 'all' | Task['status']
const filters: Filter[] = ['all', 'todo', 'doing', 'done']
const filter = ref<Filter>('all')

const visible = computed(() =>
  filter.value === 'all' ? tasks.value : tasks.value.filter(t => t.status === filter.value)
)

function count(f: Filter) {
  return f === 'all' ? tasks.value.length : tasks.value.filter(t => t.status === f).length
}

async function onCreate(title: string) {
  await create(title)
  refresh()
}

async function onUpdate(id: string, input: TaskInput) {
  await update(id, input)
  refresh()
}

async function onRemove(id: string) {
  await remove(id)
  refresh()
}

let timer: ReturnType<typeof setInterval> | undefined

onMounted(() => {
  load()
  refresh()
  timer = setInterval(refresh, 30000)
})

onBeforeUnmount(() => clearInterval(timer))
</script>

<template>
  <main class="mx-auto max-w-2xl space-y-6 p-6">
    <header>
      <h1 class="text-2xl font-bold">Tasklog</h1>
    </header>
    <StatsPanel :summary="summary" :activity="activity" :updated-at="updatedAt" :stale="stale" />
    <DemoPanel />
    <TaskForm :busy="busy" @create="onCreate" />
    <p v-if="errorMsg" class="rounded bg-red-100 px-3 py-2 text-sm text-red-700" data-testid="error">{{ errorMsg }}</p>
    <nav class="flex gap-2" data-testid="status-filter">
      <button
        v-for="f in filters"
        :key="f"
        class="rounded-full px-3 py-1 text-sm capitalize"
        :class="filter === f ? 'bg-slate-900 text-white' : 'bg-white text-slate-600 border border-slate-200'"
        @click="filter = f"
      >
        {{ f }} <span class="opacity-60">{{ count(f) }}</span>
      </button>
    </nav>
    <TaskList :tasks="visible" @update="onUpdate" @remove="onRemove" />
    <p v-if="!visible.length && tasks.length" class="text-center text-sm text-slate-400">No {{ filter }} tasks.</p>
  </main>
</template>
