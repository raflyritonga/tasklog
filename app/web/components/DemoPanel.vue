<script setup lang="ts">
interface LeverState {
  latency_ms: number
  error_rate: number
}

const state = ref<LeverState>({ latency_ms: 0, error_rate: 0 })

async function refresh() {
  state.value = await $fetch<LeverState>('/api/demo')
}

async function injectLatency() {
  state.value = await $fetch<LeverState>('/api/demo/latency', { method: 'POST', body: { ms: 800 } })
}

async function injectErrors() {
  state.value = await $fetch<LeverState>('/api/demo/errors', { method: 'POST', body: { rate: 0.5 } })
}

async function reset() {
  state.value = await $fetch<LeverState>('/api/demo/reset', { method: 'POST' })
}

onMounted(refresh)
</script>

<template>
  <section class="rounded border border-amber-300 bg-amber-50 p-4">
    <div class="flex items-center justify-between">
      <h2 class="font-semibold">Demo levers</h2>
      <p class="text-sm text-slate-600" data-testid="lever-state">
        latency {{ state.latency_ms }} ms · errors {{ Math.round(state.error_rate * 100) }}%
      </p>
    </div>
    <div class="mt-3 flex gap-2">
      <button class="rounded bg-amber-600 px-3 py-1.5 text-sm text-white" data-testid="lever-latency" @click="injectLatency">
        Latency 800 ms
      </button>
      <button class="rounded bg-red-600 px-3 py-1.5 text-sm text-white" data-testid="lever-errors" @click="injectErrors">
        Errors 50%
      </button>
      <button class="rounded bg-slate-700 px-3 py-1.5 text-sm text-white" data-testid="lever-reset" @click="reset">
        Reset
      </button>
    </div>
  </section>
</template>
