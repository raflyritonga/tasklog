<script setup lang="ts">
const config = useRuntimeConfig().public

const options = [
  { value: 'datadog', label: 'Datadog', ready: Boolean(config.ddRumAppId && config.ddRumClientToken) },
  { value: 'dynatrace', label: 'Dynatrace', ready: Boolean(config.dtRumScriptUrl) },
  { value: 'elastic', label: 'Elastic', ready: Boolean(config.elasticApmEndpoint) }
]

const current = ref(String(config.rumProvider || 'datadog'))

onMounted(() => {
  const stored = window.localStorage.getItem('tasklog-rum-provider')
  if (stored && options.some((o) => o.value === stored)) {
    current.value = stored
  }
})

function switchProvider(event: Event) {
  const value = (event.target as HTMLSelectElement).value
  window.localStorage.setItem('tasklog-rum-provider', value)
  window.location.reload()
}
</script>

<template>
  <div
    class="fixed right-3 top-3 z-50 flex items-center gap-2 rounded-lg bg-white/90 px-3 py-1.5 text-sm shadow ring-1 ring-slate-200"
    title="Which RUM SDK the browser loads. Switching reloads the page - RUM SDKs cannot be unloaded at runtime."
  >
    <span class="text-slate-500">RUM</span>
    <select
      :value="current"
      class="bg-transparent font-medium text-slate-800 focus:outline-none"
      @change="switchProvider"
    >
      <option v-for="o in options" :key="o.value" :value="o.value" :disabled="!o.ready">
        {{ o.label }}{{ o.ready ? '' : ' (no creds)' }}
      </option>
    </select>
  </div>
</template>
