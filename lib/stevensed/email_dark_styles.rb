# frozen_string_literal: true

module Stevensed
  # StevensED: one deliberate dark palette for every email (rendered by shared/_email_dark_styles).
  # RULES apply under prefers-color-scheme: dark (Apple Mail, Outlook for Mac and iOS, Gmail apps that honour it).
  # Outlook then recolours on top of that: it lightens very dark backgrounds (deep navy became slate-lavender in
  # Outlook for Mac) and turns white into its own dark grey, while light text and mid-tone colours pass through.
  # OUTLOOK_RULES therefore apply only when Outlook marks an element as recoloured ([data-ogsb] / [data-ogsc], present
  # only in Outlook's dark mode): backgrounds go back to their light values so Outlook darkens them natively, and the
  # button returns to navy with white text. Diagnosed with a test message in new Outlook for Mac, 27 November 2026.
  module EmailDarkStyles
    RULES = {
      '.se-bg' => 'background-color:#141A2E !important;',
      '.se-text, .se-content, .se-content p, .se-strong' => 'color:#E9E3D8 !important;',
      '.se-title' => 'color:#F7F5F1 !important;',
      '.se-muted' => 'color:#B7C0CC !important;',
      '.se-rule, .se-cell, .se-details' => 'border-color:#3A4670 !important;',
      '.se-panel' => 'background-color:#1C2440 !important;border-color:#5B6A99 !important;',
      '.se-label-cell' => 'background-color:#1C2440 !important;color:#C9D0DE !important;',
      '.se-content a, .se-link' => 'color:#F2C4C6 !important;',
      '.se-header' => 'background-color:#2F3E68 !important;',
      '.se-header-title' => 'color:#FFFFFF !important;',
      '.se-header-muted' => 'color:#D5DBE7 !important;',
      '.se-accent' => 'background-color:#C13F44 !important;',
      '.se-footer' => 'background-color:#0E1324 !important;color:#C9D0DE !important;',
      '.se-footer strong, .se-footer a' => 'color:#FFFFFF !important;',
      '.se-footer-muted' => 'color:#AEB8CC !important;border-color:#3A4670 !important;',
      '.se-button td.se-button-cell, .se-button a.se-button-link' =>
        'background-color:#F7F5F1 !important;color:#1F2948 !important;',
      '.se-code' => 'background-color:#1C2440 !important;color:#F7F5F1 !important;border-color:#3A4670 !important;',
      '.se-tag-success' =>
        'color:#A9DDB4 !important;background-color:#1D3324 !important;border-color:#3D6E49 !important;',
      '.se-tag-danger' =>
        'color:#F5C2C4 !important;background-color:#3A1E22 !important;border-color:#7A3A40 !important;',
      '.se-tag-notice' =>
        'color:#EFD597 !important;background-color:#33290F !important;border-color:#6B5520 !important;'
    }.freeze

    OUTLOOK_RULES = {
      '.se-bg' => 'background-color:#FFFFFF !important;',
      '.se-panel, .se-label-cell, .se-code' => 'background-color:#F7F5F1 !important;',
      '.se-footer' => 'background-color:#1F2948 !important;',
      '.se-button td.se-button-cell, .se-button a.se-button-link' =>
        'background-color:#1F2948 !important;color:#FFFFFF !important;',
      '.se-tag-success' => 'background-color:#EAF3EC !important;',
      '.se-tag-danger' => 'background-color:#FBEDED !important;',
      '.se-tag-notice' => 'background-color:#FBF3E2 !important;'
    }.freeze

    OUTLOOK_ATTRIBUTES = %w[data-ogsb data-ogsc].freeze

    module_function

    # Matches the element when Outlook marks it or any ancestor, e.g. "[data-ogsb] .se-bg, .se-bg[data-ogsb]".
    def outlook_selector(selector)
      selector.split(/\s*,\s*/).flat_map do |part|
        OUTLOOK_ATTRIBUTES.flat_map { |attr| ["[#{attr}] #{part}", part.sub(/(\.[\w-]+)\z/, "\\1[#{attr}]")] }
      end.join(', ')
    end
  end
end
