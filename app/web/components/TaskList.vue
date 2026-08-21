<script setup lang="ts">
import type { Task, TaskInput } from '~/composables/useTasks'

defineProps<{ tasks: Task[] }>()

const emit = defineEmits<{ update: [id: string, input: TaskInput], remove: [id: string] }>()

const editingId = ref('')
const editingTitle = ref('')

function startEdit(task: Task) {
  editingId.value = task.id
  editingTitle.value = task.title
}

function saveEdit(task: Task) {
  emit('update', task.id, { title: editingTitle.value, status: task.status })
  editingId.value = ''
}

function setStatus(task: Task, event: Event) {
  const status = (event.target as HTMLSelectElement).value
  emit('update', task.id, { title: task.title, status })
}
</script>

<template>
  <ul class="space-y-2" data-testid="task-list">
    <li
      v-for="task in tasks"
      :key="task.id"
      class="flex items-center gap-3 rounded border border-slate-200 bg-white px-3 py-2"
    >
      <select
        :value="task.status"
        class="rounded border border-slate-300 px-2 py-1 text-sm"
        data-testid="task-status"
        @change="setStatus(task, $event)"
      >
        <option value="todo">todo</option>
        <option value="doing">doing</option>
        <option value="done">done</option>
      </select>
      <template v-if="editingId === task.id">
        <input
          v-model="editingTitle"
          class="flex-1 rounded border border-slate-300 px-2 py-1"
          data-testid="edit-task-title"
          @keyup.enter="saveEdit(task)"
        >
        <button class="text-sm text-emerald-700" data-testid="save-task" @click="saveEdit(task)">Save</button>
      </template>
      <template v-else>
        <span class="flex-1" :class="{ 'text-slate-400 line-through': task.status === 'done' }" data-testid="task-title">
          {{ task.title }}
        </span>
        <button class="text-sm text-slate-500" data-testid="edit-task" @click="startEdit(task)">Edit</button>
      </template>
      <button class="text-sm text-red-600" data-testid="delete-task" @click="emit('remove', task.id)">Delete</button>
    </li>
  </ul>
</template>
