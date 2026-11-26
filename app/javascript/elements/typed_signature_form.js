// StevensED: "Type" option for the profile signature and initials. Renders the typed text in
// Dancing Script on a canvas and submits it as a PNG, like the Draw option.
import { target, targetable } from '@github/catalyst/lib/targetable'
import { cropCanvasAndExportToPNG } from '../submission_form/crop_canvas'

let fontLoadPromise = null

function loadFont () {
  if (!fontLoadPromise) {
    const font = new FontFace('Dancing Script', 'url(/fonts/DancingScript-Regular.otf) format("opentype")')

    fontLoadPromise = font.load().then((loaded) => document.fonts.add(loaded)).catch(() => {})
  }

  return fontLoadPromise
}

export default targetable(class extends HTMLElement {
  static [target.static] = ['text', 'canvas', 'input', 'button']

  connectedCallback () {
    loadFont().then(() => this.draw())

    this.text.addEventListener('input', () => this.draw())
    this.resizeObserver = new ResizeObserver(() => requestAnimationFrame(() => this.draw()))
    this.resizeObserver.observe(this.canvas.parentNode)

    this.button.addEventListener('click', (e) => {
      e.preventDefault()

      if (!this.text.value.trim()) return this.text.focus()

      this.button.disabled = true
      this.submit()
    })
  }

  disconnectedCallback () {
    this.resizeObserver?.disconnect()
  }

  draw () {
    const scale = 3
    const width = this.canvas.parentNode.clientWidth
    const height = Math.round(width / 3)

    this.canvas.width = width * scale
    this.canvas.height = height * scale
    this.canvas.style.width = `${width}px`
    this.canvas.style.height = `${height}px`

    const ctx = this.canvas.getContext('2d')
    ctx.setTransform(scale, 0, 0, scale, 0, 0)
    ctx.clearRect(0, 0, width, height)

    const text = this.text.value.trim()
    if (!text) return

    let size = Math.min(72, height * 0.6)
    ctx.font = `${size}px "Dancing Script"`

    while (ctx.measureText(text).width > width * 0.9 && size > 12) {
      size -= 2
      ctx.font = `${size}px "Dancing Script"`
    }

    ctx.fillStyle = '#000'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.fillText(text, width / 2, height / 2)
  }

  async submit () {
    const blob = await cropCanvasAndExportToPNG(this.canvas)
    const file = new File([blob], 'signature.png', { type: 'image/png' })
    const dataTransfer = new DataTransfer()

    dataTransfer.items.add(file)
    this.input.files = dataTransfer.files

    this.closest('form').requestSubmit()
  }
})
