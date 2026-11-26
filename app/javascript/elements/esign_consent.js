// StevensED: consent to electronic records and signatures before the document is shown for signing.
export default class extends HTMLElement {
  connectedCallback () {
    this.checkbox = this.querySelector('input[type="checkbox"]')
    this.button = this.querySelector('[data-role="continue"]')
    this.error = this.querySelector('[data-role="error"]')

    this.checkbox.addEventListener('change', () => {
      this.button.disabled = !this.checkbox.checked
    })

    this.button.addEventListener('click', () => this.submit())

    document.documentElement.classList.add('se-gate-open')
    this.checkbox.focus()
  }

  disconnectedCallback () {
    document.documentElement.classList.remove('se-gate-open')
  }

  async submit () {
    if (!this.checkbox.checked) return

    this.button.disabled = true
    this.error.hidden = true

    try {
      const resp = await fetch(this.dataset.url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: new URLSearchParams({ agree: '1' })
      })

      if (!resp.ok) throw new Error(resp.status)

      this.remove()
    } catch (e) {
      this.error.hidden = false
      this.button.disabled = false
    }
  }
}
