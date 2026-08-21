type PublicConfig = {
  rumProvider: string
  version: string
  ddSite: string
  ddRumAppId: string
  ddRumClientToken: string
  dtRumScriptUrl: string
  elasticApmEndpoint: string
}

export default defineNuxtPlugin(() => {
  const config = useRuntimeConfig().public as PublicConfig
  switch (config.rumProvider) {
    case 'datadog':
      initDatadog(config)
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
})

async function initDatadog(config: PublicConfig) {
  if (!config.ddRumAppId || !config.ddRumClientToken) {
    return
  }
  const { datadogRum } = await import('@datadog/browser-rum')
  datadogRum.init({
    applicationId: config.ddRumAppId,
    clientToken: config.ddRumClientToken,
    site: config.ddSite.includes('.') ? config.ddSite : `${config.ddSite || 'us1'}.datadoghq.com`,
    service: 'tasklog-web',
    env: 'dev',
    version: config.version,
    sessionSampleRate: 100,
    trackUserInteractions: true,
    trackResources: true,
    trackLongTasks: true,
    allowedTracingUrls: [/^https?:\/\/localhost(:\d+)?\//, /^https?:\/\/tasklog-demo\.orb\.local\//]
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
