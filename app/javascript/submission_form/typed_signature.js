// StevensED: typed signatures and initials are set in MonteCarlo (SIL Open Font License 1.1, self-hosted in
// public/fonts). The server renders typed text with the same file (Submitters::GenerateFontImage).
const TYPED_SIGNATURE_FONT = 'MonteCarlo'
const TYPED_SIGNATURE_FONT_PATH = '/fonts/MonteCarlo-Regular.ttf'

const fontLoadPromises = {}

function loadTypedSignatureFont (baseUrl = '') {
  if (!fontLoadPromises[baseUrl]) {
    const font = new FontFace(TYPED_SIGNATURE_FONT, `url(${baseUrl}${TYPED_SIGNATURE_FONT_PATH}) format("truetype")`)

    fontLoadPromises[baseUrl] = font.load().then((loadedFont) => {
      document.fonts.add(loadedFont)
    }).catch((error) => {
      console.error('Font loading failed:', error)
    })
  }

  return fontLoadPromises[baseUrl]
}

// Draws the text centred in a width x height box (CSS pixels of an already scaled context), at most maxFontSize
// and shrunk until its ink fits inside the padding, so long names stay within the box and never touch its edges.
function drawTypedText (context, text, { width, height, maxFontSize, paddingX = 0.06, paddingY = 0.16, color = '#000000' }) {
  context.clearRect(0, 0, width, height)

  if (!text) return

  const maxWidth = width * (1 - paddingX * 2)
  const maxHeight = height * (1 - paddingY * 2)

  const measure = (size) => {
    context.font = `${size}px "${TYPED_SIGNATURE_FONT}"`

    const metrics = context.measureText(text)

    return {
      metrics,
      inkWidth: metrics.actualBoundingBoxLeft + metrics.actualBoundingBoxRight,
      inkHeight: metrics.actualBoundingBoxAscent + metrics.actualBoundingBoxDescent
    }
  }

  let size = Math.max(Math.floor(maxFontSize), 6)
  let box = measure(size)

  while ((box.inkWidth > maxWidth || box.inkHeight > maxHeight) && size > 6) {
    size -= 1
    box = measure(size)
  }

  context.fillStyle = color
  context.textAlign = 'left'
  context.textBaseline = 'alphabetic'
  context.fillText(
    text,
    (width - box.inkWidth) / 2 + box.metrics.actualBoundingBoxLeft,
    (height - box.inkHeight) / 2 + box.metrics.actualBoundingBoxAscent
  )
}

export { TYPED_SIGNATURE_FONT, loadTypedSignatureFont, drawTypedText }
