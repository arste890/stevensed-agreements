import { target, targetable } from '@github/catalyst/lib/targetable'

export default targetable(class extends HTMLElement {
  static [target.static] = ['defaultButton', 'loadingButton']

  connectedCallback () {
    this.addEventListener('click', () => this.downloadFiles())
    this.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        this.downloadFiles()
      }
    })
  }

  toggleState () {
    this.defaultButton?.classList?.toggle('hidden')
    this.loadingButton?.classList?.toggle('hidden')
  }

  downloadFiles () {
    if (!this.dataset.src) return

    const download = window.webkit?.messageHandlers?.download

    if (download) {
      this.toggleState()

      document.addEventListener('native:download-end', () => this.toggleState(), { once: true })

      return download.postMessage({ src: this.dataset.src })
    }

    this.toggleState()

    if (this.errorElement) this.errorElement.textContent = ''

    fetch(this.dataset.src).then(async (response) => {
      if (response.ok) {
        const urls = await response.json()
        const isMobileSafariIos = 'ontouchstart' in window && navigator.maxTouchPoints > 0 && /AppleWebKit/i.test(navigator.userAgent)
        const isSafariIos = isMobileSafariIos || /iPhone|iPad|iPod/i.test(navigator.userAgent)

        if (isSafariIos && urls.length > 1) {
          this.downloadSafariIos(urls)
        } else {
          this.downloadUrls(urls)
        }
      } else {
        this.toggleState()
        this.showError()
      }
    }).catch(() => {
      this.toggleState()
      this.showError()
    })
  }

  // StevensED: a failed download is reported next to the button (announced to screen readers), not in an alert.
  showError () {
    if (!this.errorElement) {
      this.errorElement = document.createElement('p')
      this.errorElement.setAttribute('role', 'alert')
      this.errorElement.style.cssText = 'margin-top: 0.5rem; font-size: 0.875rem; text-align: center; color: #b42318;'
      this.insertAdjacentElement('afterend', this.errorElement)
    }

    this.errorElement.textContent = ''

    setTimeout(() => {
      this.errorElement.textContent = this.dataset.errorMessage || 'The files could not be downloaded. Please try again.'
    }, 50)
  }

  downloadUrls (urls) {
    const fileRequests = urls.map((url) => {
      return () => {
        return fetch(url).then(async (resp) => {
          const blobUrl = URL.createObjectURL(await resp.blob())
          const link = document.createElement('a')

          link.href = blobUrl
          link.setAttribute('download', decodeURI(url.split('/').pop()))

          link.click()

          URL.revokeObjectURL(blobUrl)
        })
      }
    })

    fileRequests.reduce(
      (prevPromise, request) => prevPromise.then(() => request()),
      Promise.resolve()
    ).finally(() => {
      this.toggleState()
    })
  }

  downloadSafariIos (urls) {
    const fileRequests = urls.map((url) => {
      return fetch(url).then(async (resp) => {
        const blob = await resp.blob()
        const blobUrl = URL.createObjectURL(blob.slice(0, blob.size, 'application/octet-stream'))
        const link = document.createElement('a')

        link.href = blobUrl
        link.setAttribute('download', decodeURI(url.split('/').pop()))

        return link
      })
    })

    Promise.all(fileRequests).then((links) => {
      links.forEach((link, index) => {
        setTimeout(() => {
          link.click()

          URL.revokeObjectURL(link.href)
        }, index * 50)
      })
    }).finally(() => {
      this.toggleState()
    })
  }
})
