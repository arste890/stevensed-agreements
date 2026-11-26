# frozen_string_literal: true

module Stevensed
  # Field names in StevensED templates carry the form's section number ("10. Full legal name") so that they sort
  # and can be traced to the form. For display, the number is left out.
  module FieldLabel
    SECTION_NUMBER = /\A\s*\d+[A-Za-z]?(?:\.\d+)*[.)]\s+/

    module_function

    # With role, a leading "Role — " (as in "Student — Signature") is left out too, for lists already grouped by
    # signer.
    def display(name, role: nil)
      name = name.to_s.sub(SECTION_NUMBER, '')
      name = name.sub(/\A#{Regexp.escape(role.to_s)}\s*[—–:-]\s+/i, '') if role.present?

      name.presence || name
    end
  end
end
