# frozen_string_literal: true

module Stevensed
  # Field names in StevensED templates carry the form's section number ("10. Full legal name") so that they sort
  # and can be traced to the form. For display, the number is left out.
  module FieldLabel
    SECTION_NUMBER = /\A\s*\d+[A-Za-z]?(?:\.\d+)*[.)]\s+/

    module_function

    def display(name)
      name.to_s.sub(SECTION_NUMBER, '')
    end
  end
end
