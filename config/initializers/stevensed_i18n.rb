# frozen_string_literal: true

# StevensED: white-label upstream strings. "DocuSeal" in translations becomes the StevensED product name,
# and DocuSeal policy links point to StevensED's. The DocuSeal attribution required by the licence is kept
# on the Legal notices page (app/views/legal_notices/show.html.erb), which does not use these strings.
Rails.application.config.after_initialize { Stevensed::I18nWhiteLabel.install! }
