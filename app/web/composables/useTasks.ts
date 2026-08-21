export interface Task {
  id: string
  title: string
  status: 'todo' | 'doing' | 'done'
  created_at: string
  updated_at: string
}

export interface TaskInput {
  title: string
  status: string
}

export function useTasks() {
  const tasks = ref<Task[]>([])
  const busy = ref(false)
  const errorMsg = ref('')

  async function run<T>(fn: () => Promise<T>): Promise<T | undefined> {
    busy.value = true
    errorMsg.value = ''
    try {
      return await fn()
    } catch (e) {
      const err = e as { data?: { error?: string }, message?: string }
      errorMsg.value = err.data?.error || err.message || 'request failed'
      return undefined
    } finally {
      busy.value = false
    }
  }

  async function load() {
    const data = await run(() => $fetch<Task[]>('/api/tasks'))
    if (data) {
      tasks.value = data
    }
  }

  async function create(title: string) {
    const created = await run(() => $fetch<Task>('/api/tasks', { method: 'POST', body: { title } }))
    if (created) {
      await load()
    }
  }

  async function update(id: string, input: TaskInput) {
    const updated = await run(() => $fetch<Task>(`/api/tasks/${id}`, { method: 'PUT', body: input }))
    if (updated) {
      await load()
    }
  }

  async function remove(id: string) {
    await run(() => $fetch(`/api/tasks/${id}`, { method: 'DELETE' }))
    await load()
  }

  return { tasks, busy, errorMsg, load, create, update, remove }
}
