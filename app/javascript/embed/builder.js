// StevensED Agreements: embedded template builder.
//
// Usage on an allowed StevensED site:
//   <script src="https://agreements.stevensed.org/js/builder.js"></script>
//   <stevensed-builder data-token="JWT_FROM_YOUR_SERVER"></stevensed-builder>
//
// The same element is registered under a second name for compatibility with existing markup.
// The token is a short lived HS256 JSON Web Token minted on your server (see Settings, Embedding).
// It is sent to the iframe with a POST request, so it does not appear in the iframe address.
// The element dispatches the DOM events init, load and save.
(function () {
  if (window.customElements.get('stevensed-builder')) return

  const scriptOrigin = document.currentScript ? new URL(document.currentScript.src).origin : null

  let counter = 0

  class StevensedBuilder extends HTMLElement {
    connectedCallback () {
      if (this.iframe) return

      if (!scriptOrigin) {
        console.error(this.localName + ': load builder.js with a script tag')

        return
      }

      if (!this.dataset.token) {
        console.error(this.localName + ': data-token is required')

        return
      }

      counter += 1

      this.appOrigin = scriptOrigin
      this.firedEvents = {}

      const name = 'stevensed_builder_' + counter + '_' + Date.now()

      this.iframe = document.createElement('iframe')
      this.iframe.name = name
      this.iframe.title = this.dataset.title || 'Template builder'
      this.iframe.style.cssText = 'display:block;width:100%;border:0;height:' + (this.dataset.height || '100vh')

      this.onMessage = this.onMessage.bind(this)
      this.onLoad = this.onLoad.bind(this)

      window.addEventListener('message', this.onMessage)
      this.iframe.addEventListener('load', this.onLoad)

      this.appendChild(this.iframe)

      const form = document.createElement('form')

      form.method = 'post'
      form.action = this.appOrigin + '/embed/builder'
      form.target = name
      form.style.display = 'none'

      const input = document.createElement('input')

      input.type = 'hidden'
      input.name = 'token'
      input.value = this.dataset.token

      form.appendChild(input)
      this.appendChild(form)

      this.emit('init', {})

      form.submit()
      form.remove()
    }

    disconnectedCallback () {
      window.removeEventListener('message', this.onMessage)
      this.iframe?.remove()
      this.iframe = null
    }

    onLoad () {
      try {
        this.iframe.contentWindow.postMessage({ type: 'stevensed:hello' }, this.appOrigin)
      } catch (e) {
        // The iframe has not navigated to the application yet.
      }
    }

    onMessage (event) {
      if (!this.iframe || event.source !== this.iframe.contentWindow || event.origin !== this.appOrigin) return

      const data = event.data

      if (!data || typeof data.type !== 'string' || data.type.indexOf('stevensed:') !== 0) return

      if (data.type === 'stevensed:ready') {
        if (!this.firedEvents.load) {
          this.firedEvents.load = true
          this.emit('load', data.detail || {})
        }
      } else if (data.type === 'stevensed:builder-saved') {
        this.emit('save', data.detail || {})
      }
    }

    emit (name, detail) {
      this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }))
    }
  }

  window.customElements.define('stevensed-builder', StevensedBuilder)

  if (!window.customElements.get('docuseal-builder')) {
    window.customElements.define('docuseal-builder', class extends StevensedBuilder {})
  }
})()
