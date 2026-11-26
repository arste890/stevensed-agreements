// StevensED: Policy Library field names carry a form or section number for the document's own numbering
// ("10. Full legal name", "102 10. Full legal name", "9. I confirm..."). Signers see the label without it.
// Only the copy shown in the signing form changes; stored field names are untouched. Mirrors the server's
// Stevensed::FieldLabel.display: a packet prefix (three digits and a space), then a section number.
const PACKET_PREFIX = /^\d{3}\s+/
const SECTION_PREFIX = /^\d+(\.\d+)*\.?\s+/

function displayFieldName (name) {
  if (typeof name !== 'string') return name

  const label = name.replace(PACKET_PREFIX, '').replace(SECTION_PREFIX, '')

  return label.trim() ? label : name
}

function withDisplayFieldNames (fields) {
  return fields.map((field) => field.name ? { ...field, name: displayFieldName(field.name) } : field)
}

export { displayFieldName, withDisplayFieldNames }
