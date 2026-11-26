# frozen_string_literal: true

module Stevensed
  # The name to show for a signer on signed documents and in the audit log: the legal name from the electronic
  # records consent (applied to the envelope, or given on the consent form itself), then the name the envelope was
  # sent to. A self-signed envelope otherwise shows the sender's account name.
  module SignerName
    module_function

    def for(submitter)
      submitter.metadata.to_h['stevensed_legal_name'].presence ||
        StevensedEsignConsent.where(submitter_id: submitter.id).pick(:legal_name).presence ||
        submitter.name.presence
    end
  end
end
