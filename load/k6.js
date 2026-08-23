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

const sourceIps = [
  '13.107.42.14', '104.244.42.1', '203.0.113.9', '91.198.174.192',
  '151.101.1.140', '200.160.2.3', '196.10.52.10', '210.87.152.1', '5.9.24.180', '49.207.180.22'
]

function clientHeaders() {
  return {
    'Content-Type': 'application/json',
    'X-Forwarded-For': sourceIps[Math.floor(Math.random() * sourceIps.length)]
  }
}


export default function () {
  const r = Math.random()
  if (r < 0.7) {
    http.get(`${base}/api/tasks`, { headers: clientHeaders() })
  } else if (r < 0.85) {
    const list = http.get(`${base}/api/tasks`, { headers: clientHeaders() })
    const tasks = list.status === 200 ? list.json() : []
    if (tasks.length > 0) {
      const task = tasks[Math.floor(Math.random() * tasks.length)]
      http.get(`${base}/api/tasks/${task.id}`, { headers: clientHeaders() })
    }
  } else if (r < 0.95) {
    const created = http.post(`${base}/api/tasks`, JSON.stringify({ title: `k6 load ${__VU}-${__ITER}` }), { headers: clientHeaders() })
    if (created.status === 201) {
      http.del(`${base}/api/tasks/${created.json().id}`, null, { headers: clientHeaders() })
    }
  } else {
    http.get(`${base}/api/reports/summary`, { headers: clientHeaders() })
  }
  sleep(0.2 + Math.random() * 0.3)
}
