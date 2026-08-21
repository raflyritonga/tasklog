<script setup lang="ts">
const { tasks, busy, errorMsg, load, create, update, remove } = useTasks()

onMounted(load)
</script>

<template>
  <main class="mx-auto max-w-2xl space-y-6 p-6">
    <header>
      <h1 class="text-2xl font-bold">Tasklog</h1>
    </header>
    <DemoPanel />
    <TaskForm :busy="busy" @create="create" />
    <p v-if="errorMsg" class="rounded bg-red-100 px-3 py-2 text-sm text-red-700" data-testid="error">{{ errorMsg }}</p>
    <TaskList :tasks="tasks" @update="update" @remove="remove" />
  </main>
</template>
