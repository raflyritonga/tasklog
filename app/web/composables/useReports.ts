export interface Summary {
  total: number
  todo: number
  doing: number
  done: number
}

export interface ActivityDay {
  day: string
  created: number
}

export function useReports() {
  const summary = ref<Summary | null>(null)
  const activity = ref<ActivityDay[]>([])
  const updatedAt = ref<Date | null>(null)
  const stale = ref(false)

  async function refresh() {
    try {
      const [s, a] = await Promise.all([
        $fetch<Summary>('/api/reports/summary'),
        $fetch<ActivityDay[]>('/api/reports/activity')
      ])
      summary.value = s
      activity.value = a
      updatedAt.value = new Date()
      stale.value = false
    } catch {
      stale.value = true
    }
  }

  return { summary, activity, updatedAt, stale, refresh }
}
