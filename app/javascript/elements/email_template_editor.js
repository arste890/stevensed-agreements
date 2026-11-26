// StevensED: email template editor (subject, heading, introduction, closing note).
// Switches the party and version shown, inserts variables and simple markdown into the last field used,
// and loads the preview or sends a test to the signed-in user.
export default class extends HTMLElement {
  connectedCallback () {
    this.lastField = null

    this.addEventListener('focusin', this.onFocusIn)
    this.addEventListener('change', this.onChange)
    this.addEventListener('click', this.onClick)

    this.dialog?.addEventListener('click', this.onDialogClick)

    this.sync()
  }

  disconnectedCallback () {
    this.removeEventListener('focusin', this.onFocusIn)
    this.removeEventListener('change', this.onChange)
    this.removeEventListener('click', this.onClick)

    this.dialog?.removeEventListener('click', this.onDialogClick)
  }

  onFocusIn = (event) => {
    if (event.target.matches('[data-field]')) {
      this.lastField = event.target
    }
  }

  onChange = (event) => {
    const role = event.target.dataset.role

    if (role === 'party' || role === 'variant') {
      this.sync()
    } else if (role === 'variable' && event.target.value) {
      this.insertText(event.target.value)

      event.target.value = ''
    }
  }

  onClick = (event) => {
    const button = event.target.closest('button[data-role]')

    if (!button || !this.contains(button)) return

    const role = button.dataset.role

    if (role === 'bold') {
      this.wrapSelection('**', '**')
    } else if (role === 'link') {
      this.insertLink()
    } else if (role === 'preview') {
      this.preview()
    } else if (role === 'test') {
      this.sendTest(button)
    } else if (role === 'close') {
      this.dialog.close()
    }
  }

  onDialogClick = (event) => {
    if (event.target === this.dialog) {
      this.dialog.close()
    }
  }

  get dialog () {
    return this.querySelector('[data-role="dialog"]')
  }

  get groups () {
    return Array.from(this.querySelectorAll('[data-party]'))
  }

  get activeGroup () {
    const select = this.querySelector('[data-role="party"]')
    const party = select ? select.value : ''

    return this.groups.find((group) => group.dataset.party === party) || this.groups[0]
  }

  get allPartiesGroup () {
    return this.groups.find((group) => group.dataset.party === '')
  }

  activeVariant (group) {
    const checked = group.querySelector('[data-role="variant"]:checked')
    const variants = group.querySelectorAll('[data-variant]')

    return checked ? checked.value : (variants[0]?.dataset.variant || '')
  }

  sync () {
    const active = this.activeGroup

    this.groups.forEach((group) => {
      group.hidden = group !== active

      const variant = this.activeVariant(group)

      group.querySelectorAll('[data-variant]').forEach((element) => {
        element.hidden = element.dataset.variant !== variant
      })
    })

    if (this.lastField && this.lastField.closest('[hidden]')) {
      this.lastField = null
    }
  }

  get targetField () {
    if (this.lastField && !this.lastField.closest('[hidden]')) {
      return this.lastField
    }

    return Array.from(this.activeGroup.querySelectorAll('textarea[data-field]')).find((el) => !el.closest('[hidden]'))
  }

  insertText (text) {
    const field = this.targetField

    if (!field) return

    const start = field.selectionStart ?? field.value.length
    const end = field.selectionEnd ?? field.value.length

    field.setRangeText(text, start, end, 'end')
    field.dispatchEvent(new Event('input', { bubbles: true }))
    field.focus()
  }

  wrapSelection (before, after) {
    const field = this.targetField

    if (!field) return

    const start = field.selectionStart ?? field.value.length
    const end = field.selectionEnd ?? field.value.length
    const selected = field.value.slice(start, end)

    field.setRangeText(`${before}${selected}${after}`, start, end, 'select')

    if (!selected) {
      field.setSelectionRange(start + before.length, start + before.length)
    }

    field.focus()
  }

  insertLink () {
    const field = this.targetField

    if (!field) return

    const url = window.prompt(this.dataset.linkPrompt, 'https://')

    if (!url || url === 'https://') {
      field.focus()

      return
    }

    const start = field.selectionStart ?? field.value.length
    const end = field.selectionEnd ?? field.value.length
    const label = field.value.slice(start, end) || url

    field.setRangeText(`[${label}](${url})`, start, end, 'end')
    field.focus()
  }

  // Fields of the visible party and version; blank party fields use the text for all parties.
  buildBody () {
    const group = this.activeGroup
    const variant = this.activeVariant(group)
    const fallback = group === this.allPartiesGroup ? null : this.allPartiesGroup
    const body = new FormData()

    body.append('variant', variant)

    group.querySelectorAll('[data-field]').forEach((field) => {
      const fieldVariant = field.closest('[data-variant]')

      if (fieldVariant && fieldVariant.dataset.variant !== variant) return

      let value = field.value

      if (!value.trim() && fallback) {
        value = fallback.querySelector(`[data-field="${field.dataset.field}"]`)?.value || ''
      }

      body.append(`parts[${field.dataset.field}]`, value)
    })

    return body
  }

  request (url) {
    return fetch(url, {
      method: 'POST',
      body: this.buildBody(),
      headers: {
        Accept: 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
      }
    }).then(async (resp) => {
      let data = {}

      try {
        data = await resp.json()
      } catch (err) {
        console.error(err)
      }

      if (!resp.ok) {
        throw new Error(data.error || this.dataset.previewFailed)
      }

      return data
    })
  }

  setStatus (text) {
    const status = this.querySelector('[data-role="status"]')

    if (status) status.textContent = text || ''
  }

  preview () {
    this.setStatus('')

    this.request(this.dataset.previewUrl).then((data) => {
      this.querySelector('[data-role="frame"]').srcdoc = data.html
      this.querySelector('[data-role="preview-subject"]').textContent = data.subject

      this.dialog.showModal()
      this.dialog.querySelector('[data-role="close"]')?.focus()
    }).catch((err) => {
      this.setStatus(err.message)
    })
  }

  sendTest (button) {
    button.disabled = true

    this.setStatus('')

    this.request(this.dataset.testUrl).then((data) => {
      this.setStatus(data.message)
    }).catch((err) => {
      this.setStatus(err.message)
    }).finally(() => {
      button.disabled = false
    })
  }
}
