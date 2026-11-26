// StevensED Agreements: bridge loaded inside embedded pages.
//
// It answers the host page only after the host has introduced itself with a stevensed:hello message
// from an origin on the allow list (EMBED_ALLOWED_ORIGINS). Every message is posted to that origin only.
(function () {
  if (window.parent === window || window.stevensedEmbedBridge) return

  window.stevensedEmbedBridge = true

  const STORAGE_KEY = 'stevensed:embed-parent-origin'

  let parentOrigin = null
  let lastHeight = null

  const readMeta = () => {
    const meta = document.querySelector('meta[name="stevensed-embed"]')

    return meta ? meta.dataset : null
  }

  const patternToRegExp = (pattern) => {
    const match = /^(https?):\/\/(\*\.)?([a-z0-9.-]+)(:\d+)?$/.exec(pattern)

    if (!match) return null

    const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const host = match[2] ? '[a-z0-9-]+(\\.[a-z0-9-]+)*\\.' + escape(match[3]) : escape(match[3])

    return new RegExp('^' + match[1] + ':\\/\\/' + host + escape(match[4] || '') + '$')
  }

  const isAllowedOrigin = (origin) => {
    const meta = readMeta()

    if (!meta || !origin) return false
    if (origin === window.location.origin) return true

    let patterns = []

    try {
      patterns = JSON.parse(meta.allowedOrigins || '[]')
    } catch (e) {
      return false
    }

    return patterns.some((pattern) => {
      const regexp = patternToRegExp(String(pattern).toLowerCase())

      return regexp && regexp.test(origin.toLowerCase())
    })
  }

  const post = (type, detail) => {
    if (!parentOrigin) return

    window.parent.postMessage({ type, detail }, parentOrigin)
  }

  const pageDetail = () => {
    const meta = readMeta() || {}
    const detail = { state: meta.state || 'page' }

    if (meta.submitterId) detail.submitter_id = Number(meta.submitterId)
    if (meta.submitterSlug) detail.submitter_slug = meta.submitterSlug
    if (meta.templateId) detail.template_id = Number(meta.templateId)

    return detail
  }

  const completionDetail = () => {
    const meta = readMeta() || {}
    const detail = pageDetail()

    if (meta.downloadUrl) detail.download_url = meta.downloadUrl

    return detail
  }

  const isFillPage = () => {
    const meta = readMeta() || {}

    return meta.state === 'form' || meta.state === 'builder'
  }

  const reportSize = (force) => {
    const fill = isFillPage()
    // The body height can shrink as well as grow, unlike the document height, which is at least the iframe height.
    const height = fill ? null : (document.body ? document.body.scrollHeight : document.documentElement.scrollHeight) + 24
    const key = fill ? 'fill' : height

    if (!force && key === lastHeight) return

    lastHeight = key

    post('stevensed:resize', fill ? { fill: true } : { fill: false, height })
  }

  const reportState = () => {
    const detail = pageDetail()

    post('stevensed:ready', detail)
    reportSize(true)

    if (detail.state === 'completed') post('stevensed:completed', completionDetail())
    if (detail.state === 'declined') post('stevensed:declined', pageDetail())
  }

  try {
    const stored = window.sessionStorage.getItem(STORAGE_KEY)

    if (stored && isAllowedOrigin(stored)) parentOrigin = stored
  } catch (e) {
    // Storage may be unavailable in partitioned iframes.
  }

  window.addEventListener('message', (event) => {
    if (event.source !== window.parent) return
    if (!event.data || event.data.type !== 'stevensed:hello') return
    if (!isAllowedOrigin(event.origin)) return

    parentOrigin = event.origin

    try {
      window.sessionStorage.setItem(STORAGE_KEY, parentOrigin)
    } catch (e) {
      // Storage may be unavailable in partitioned iframes.
    }

    reportState()
  })

  window.addEventListener('stevensed:form-completed', () => {
    post('stevensed:completed', completionDetail())
  })

  window.addEventListener('stevensed:builder-saved', (event) => {
    post('stevensed:builder-saved', Object.assign(pageDetail(), event.detail || {}))
  })

  document.addEventListener('turbo:load', () => reportState())

  const startObserver = () => {
    if (window.ResizeObserver) {
      new window.ResizeObserver(() => reportSize(false)).observe(document.body || document.documentElement)
    } else {
      window.setInterval(() => reportSize(false), 500)
    }

    reportState()
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startObserver)
  } else {
    startObserver()
  }
})()
