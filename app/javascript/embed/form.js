// StevensED Agreements: embedded signing form.
//
// Usage on an allowed StevensED site:
//   <script src="https://agreements.stevensed.org/js/form.js"></script>
//   <stevensed-form data-src="https://agreements.stevensed.org/s/SUBMITTER_SLUG"></stevensed-form>
//
// The same element is registered under a second name for compatibility with existing markup. The element also accepts a template share link (/d/TEMPLATE_SLUG) together with data-email,
// data-name and data-phone to prefill the start form, and data-language to choose the form language.
// It dispatches the DOM events init, load, completed and declined.
(function () {
  if (window.customElements.get('stevensed-form')) return

  const scriptOrigin = document.currentScript ? new URL(document.currentScript.src).origin : null
  const PATH_REGEXP = /^\/(s|d)\/[A-Za-z0-9_-]+\/?$/

  class StevensedForm extends HTMLElement {
    connectedCallback () {
      if (this.iframe) return

      const url = this.buildUrl()

      if (!url) return

      this.appOrigin = url.origin
      this.firedEvents = {}

      this.iframe = document.createElement('iframe')
      this.iframe.src = url.toString()
      this.iframe.title = this.dataset.title || 'Signing form'
      this.iframe.setAttribute('allow', 'clipboard-write; camera')
      this.iframe.style.cssText = 'display:block;width:100%;border:0;min-height:' + (this.dataset.minHeight || '480px') + ';height:' + (this.dataset.minHeight || '480px')

      this.onMessage = this.onMessage.bind(this)
      this.onLoad = this.onLoad.bind(this)

      window.addEventListener('message', this.onMessage)
      this.iframe.addEventListener('load', this.onLoad)

      this.appendChild(this.iframe)

      this.emit('init', { src: url.toString() })
    }

    disconnectedCallback () {
      window.removeEventListener('message', this.onMessage)
      this.iframe?.remove()
      this.iframe = null
    }

    buildUrl () {
      let url

      try {
        url = new URL(this.dataset.src || '', window.location.href)
      } catch (e) {
        console.error(this.localName + ': data-src is not a valid URL')

        return null
      }

      if (scriptOrigin && url.origin !== scriptOrigin) {
        console.error(this.localName + ': data-src must point to ' + scriptOrigin)

        return null
      }

      if (!PATH_REGEXP.test(url.pathname)) {
        console.error(this.localName + ': data-src must be a signing link (/s/...) or a share link (/d/...)')

        return null
      }

      const params = { email: this.dataset.email, name: this.dataset.name, phone: this.dataset.phone, lang: this.dataset.language }

      Object.keys(params).forEach((key) => {
        if (params[key]) url.searchParams.set(key, params[key])
      })

      return url
    }

    onLoad () {
      this.iframe.contentWindow.postMessage({ type: 'stevensed:hello' }, this.appOrigin)
    }

    onMessage (event) {
      if (!this.iframe || event.source !== this.iframe.contentWindow || event.origin !== this.appOrigin) return

      const data = event.data

      if (!data || typeof data.type !== 'string' || data.type.indexOf('stevensed:') !== 0) return

      if (data.type === 'stevensed:ready') {
        this.emitOnce('load', data.detail || {})
      } else if (data.type === 'stevensed:resize') {
        this.resize(data)
      } else if (data.type === 'stevensed:completed') {
        this.emitOnce('completed', data.detail || {})
      } else if (data.type === 'stevensed:declined') {
        this.emitOnce('declined', data.detail || {})
      }
    }

    resize (data) {
      if (data.fill) {
        this.iframe.style.height = this.dataset.height || '100vh'
      } else if (typeof data.height === 'number' && data.height > 0) {
        this.iframe.style.height = Math.ceil(data.height) + 'px'
      }
    }

    emitOnce (name, detail) {
      if (this.firedEvents[name]) return

      this.firedEvents[name] = true
      this.emit(name, detail)
    }

    emit (name, detail) {
      this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }))
    }
  }

  window.customElements.define('stevensed-form', StevensedForm)

  if (!window.customElements.get('docuseal-form')) {
    window.customElements.define('docuseal-form', class extends StevensedForm {})
  }
})()
