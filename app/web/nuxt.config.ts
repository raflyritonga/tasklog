export default defineNuxtConfig({
  compatibilityDate: '2026-08-21',
  modules: ['@nuxtjs/tailwindcss'],
  runtimeConfig: {
    apiProxyTarget: '',
    public: {
      rumProvider: 'datadog',
      version: process.env.VERSION || 'dev',
      ddSite: '',
      ddRumAppId: '',
      ddRumClientToken: '',
      dtRumScriptUrl: '',
      elasticApmEndpoint: ''
    }
  }
})
