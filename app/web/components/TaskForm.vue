<script setup lang="ts">
defineProps<{ busy: boolean }>()

const emit = defineEmits<{ create: [title: string] }>()

const title = ref('')

function submit() {
  const value = title.value.trim()
  if (!value) {
    return
  }
  emit('create', value)
  title.value = ''
}
</script>

<template>
  <form class="flex gap-2" @submit.prevent="submit">
    <input
      v-model="title"
      type="text"
      maxlength="200"
      placeholder="New task title"
      class="flex-1 rounded border border-slate-300 bg-white px-3 py-2"
      data-testid="new-task-title"
    >
    <button
      type="submit"
      :disabled="busy"
      class="rounded bg-slate-900 px-4 py-2 text-white disabled:opacity-50"
      data-testid="add-task"
    >
      Add
    </button>
  </form>
</template>
