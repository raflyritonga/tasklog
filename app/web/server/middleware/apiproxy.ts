export default defineEventHandler((event) => {
  const target = useRuntimeConfig().apiProxyTarget
  if (!target || !event.path.startsWith('/api/')) {
    return
  }
  return proxyRequest(event, target + event.path)
})
