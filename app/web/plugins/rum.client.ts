import type { NuxtApp } from 'nuxt/app'
import type { Router } from 'vue-router'

type PublicConfig = {
  rumProvider: string
  version: string
  ddSite: string
  ddRumAppId: string
  ddRumClientToken: string
  dtRumScriptUrl: string
  elasticApmEndpoint: string
}

const tracingUrls = [/^https?:\/\/localhost(:\d+)?\//, /^https?:\/\/tasklog-demo\.orb\.local\//]

export default defineNuxtPlugin({
  name: 'tasklog-rum',
  enforce: 'pre',
  setup() {
    const config = useRuntimeConfig().public as PublicConfig
    const router = useRouter()
    const nuxtApp = useNuxtApp()
    switch (config.rumProvider) {
      case 'datadog':
        initDatadog(config, router, nuxtApp)
        break
      case 'dynatrace':
        initDynatrace(config)
        break
      case 'elastic':
        initElastic(config)
        break
      case 'grafana':
        break
    }
  }
})

function datadogSite(site: string) {
  if (!site) {
    return 'datadoghq.com'
  }
  return site.includes('.') ? site : `${site}.datadoghq.com`
}

async function initDatadog(config: PublicConfig, router: Router, nuxtApp: NuxtApp) {
  if (!config.ddRumAppId || !config.ddRumClientToken) {
    return
  }
  const { datadogRum } = await import('@datadog/browser-rum')
  const { nuxtRumPlugin } = await import('@datadog/browser-rum-nuxt')
  datadogRum.init({
    applicationId: config.ddRumAppId,
    clientToken: config.ddRumClientToken,
    site: datadogSite(config.ddSite),
    service: 'tasklog-web',
    env: 'dev',
    version: config.version,
    sessionSampleRate: 100,
    sessionReplaySampleRate: 20,
    trackResources: true,
    trackUserInteractions: true,
    trackLongTasks: true,
    defaultPrivacyLevel: 'mask-user-input',
    allowedTracingUrls: tracingUrls,
    plugins: [nuxtRumPlugin({ router, nuxtApp })]
  })
}

async function initElastic(config: PublicConfig) {
  if (!config.elasticApmEndpoint) {
    return
  }
  const { init } = await import('@elastic/apm-rum')
  init({
    serviceName: 'tasklog-web',
    serverUrl: config.elasticApmEndpoint,
    environment: 'dev',
    serviceVersion: config.version,
    distributedTracingOrigins: ['http://localhost:3000', 'http://tasklog-demo.orb.local']
  })
}

function initDynatrace(config: PublicConfig) {
  if (!config.dtRumScriptUrl) {
    return
  }
  useHead({ script: [{ src: config.dtRumScriptUrl, defer: true }] })
}
