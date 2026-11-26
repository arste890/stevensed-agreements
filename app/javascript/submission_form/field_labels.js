// StevensED: Policy Library field names carry a form or section number for the document's own numbering
// ("10. Full legal name", "102 10. Full legal name", "9. I confirm..."). Signers see the label without it.
// Only the copy shown in the signing form changes; stored field names are untouched. Mirrors the server's
// Stevensed::FieldLabel.display (lib/stevensed/field_label.rb), plus a packet prefix (three digits and a space).
const PACKET_PREFIX = /^\d{3}\s+/
const SECTION_NUMBER = /^\s*\d+[A-Za-z]?(?:\.\d+)*[.)]\s+/

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

function displayFieldName (name, { role } = {}) {
  if (typeof name !== 'string') return name

  let label = name.replace(PACKET_PREFIX, '').replace(SECTION_NUMBER, '')

  if (role) {
    label = label.replace(new RegExp(`^${escapeRegExp(role)}\\s*[—–:-]\\s+`, 'i'), '')
  }

  return label.trim() ? label : name
}

function withDisplayFieldNames (fields, { role } = {}) {
  return fields.map((field) => field.name ? { ...field, name: displayFieldName(field.name, { role }) } : field)
}

export { displayFieldName, withDisplayFieldNames }
