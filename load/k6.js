import http from 'k6/http'
import { sleep } from 'k6'

export const options = {
  vus: 5,
  duration: __ENV.DURATION || '10m',
  thresholds: {
    http_req_duration: ['p(95)<800']
  }
}

const base = __ENV.BASE_URL || 'http://localhost:3000'
const headers = { 'Content-Type': 'application/json' }

export default function () {
  const r = Math.random()
  if (r < 0.7) {
    http.get(`${base}/api/tasks`)
  } else if (r < 0.85) {
    const list = http.get(`${base}/api/tasks`)
    const tasks = list.status === 200 ? list.json() : []
    if (tasks.length > 0) {
      const task = tasks[Math.floor(Math.random() * tasks.length)]
      http.get(`${base}/api/tasks/${task.id}`)
    }
  } else if (r < 0.95) {
    const created = http.post(`${base}/api/tasks`, JSON.stringify({ title: `k6 load ${__VU}-${__ITER}` }), { headers })
    if (created.status === 201) {
      http.del(`${base}/api/tasks/${created.json().id}`)
    }
  } else {
    http.get(`${base}/api/reports/summary`)
  }
  sleep(0.2 + Math.random() * 0.3)
}
