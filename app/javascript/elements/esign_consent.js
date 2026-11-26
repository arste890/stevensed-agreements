// StevensED: electronic records consent step before signing. Each <form data-step> posts its fields with the step
// name; the server answers with { reload }, { redirect }, { message } or { error }.
export default class extends HTMLElement {
  connectedCallback () {
    this.error = this.querySelector('[data-role="error"]')
    this.message = this.querySelector('[data-role="message"]')

    const agree = this.querySelector('[data-role="agree"]')
    const form = this.querySelector('form[data-step]')

    agree?.addEventListener('change', () => {
      form.querySelector('[data-role="continue"]').disabled = !agree.checked
    })

    form?.addEventListener('submit', (e) => {
      e.preventDefault()
      this.post(form.dataset.step, new FormData(form), form.querySelector('[data-role="continue"]'))
    })

    this.querySelectorAll('[data-step-link]').forEach((link) => {
      link.addEventListener('click', () => this.post(link.dataset.stepLink, new FormData(), link))
    })

    document.documentElement.classList.add('se-gate-open')
    this.querySelector('input:not([type="hidden"]), button')?.focus()
  }

  disconnectedCallback () {
    document.documentElement.classList.remove('se-gate-open')
  }

  async post (step, body, button) {
    body.append('step', step)

    if (button) button.disabled = true
    if (this.error) this.error.hidden = true

    try {
      const resp = await fetch(this.dataset.url, {
        method: 'POST',
        headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content, Accept: 'application/json' },
        body
      })
      const data = await resp.json().catch(() => ({}))

      if (data.redirect) {
        window.location.assign(data.redirect)
      } else if (data.reload) {
        window.location.reload()
      } else if (data.message) {
        this.querySelectorAll('form, [data-step-link]').forEach((el) => { el.hidden = true })
        this.message.textContent = data.message
        this.message.hidden = false
      } else {
        throw new Error(data.error || 'Your answer could not be recorded. Check your connection and try again.')
      }
    } catch (e) {
      if (this.error) {
        this.error.textContent = e.message
        this.error.hidden = false
      }
      if (button) button.disabled = false
    }
  }
}
