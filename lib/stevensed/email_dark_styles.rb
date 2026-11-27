# frozen_string_literal: true

module Stevensed
  # StevensED: one deliberate dark palette for every email (rendered by shared/_email_dark_styles under
  # prefers-color-scheme: dark, for Apple Mail and other clients that honour it).
  #
  # Dark backgrounds are drawn as single-colour gradients, not background-color. New Outlook for Mac applies the
  # media query but then lightens any very dark background colour (our deep navy turned slate-lavender), while it
  # ignores background gradients entirely and turns the inline white into its own dark grey. With gradients, Apple
  # Mail shows the navy palette and Outlook shows its native dark grey under the same light text. The button keeps
  # white text in dark mode so it reads on Outlook's navy as well as on the lighter blue Apple Mail draws.
  # Diagnosed with two test messages in new Outlook for Mac, 27 November 2026.
  module EmailDarkStyles
    BACKGROUNDS = {
      '.se-bg' => '#141A2E',
      '.se-panel' => '#1C2440',
      '.se-label-cell' => '#1C2440',
      '.se-header' => '#2F3E68',
      '.se-footer' => '#0E1324',
      '.se-button td.se-button-cell, .se-button a.se-button-link' => '#34478A',
      '.se-code' => '#1C2440',
      '.se-tag-success' => '#1D3324',
      '.se-tag-danger' => '#3A1E22',
      '.se-tag-notice' => '#33290F'
    }.freeze

    COLOURS = {
      '.se-text, .se-content, .se-content p, .se-strong' => 'color:#E9E3D8 !important;',
      '.se-title' => 'color:#F7F5F1 !important;',
      '.se-muted' => 'color:#B7C0CC !important;',
      '.se-rule, .se-cell, .se-details' => 'border-color:#3A4670 !important;',
      '.se-panel' => 'border-color:#5B6A99 !important;',
      '.se-label-cell' => 'color:#C9D0DE !important;',
      '.se-content a, .se-link' => 'color:#F2C4C6 !important;',
      '.se-header-title' => 'color:#FFFFFF !important;',
      '.se-header-muted' => 'color:#D5DBE7 !important;',
      '.se-footer' => 'color:#C9D0DE !important;',
      '.se-footer strong, .se-footer a' => 'color:#FFFFFF !important;',
      '.se-footer-muted' => 'color:#AEB8CC !important;border-color:#3A4670 !important;',
      '.se-button td.se-button-cell, .se-button a.se-button-link' => 'color:#FFFFFF !important;',
      '.se-code' => 'color:#F7F5F1 !important;border-color:#3A4670 !important;',
      '.se-tag-success' => 'color:#A9DDB4 !important;border-color:#3D6E49 !important;',
      '.se-tag-danger' => 'color:#F5C2C4 !important;border-color:#7A3A40 !important;',
      '.se-tag-notice' => 'color:#EFD597 !important;border-color:#6B5520 !important;'
    }.freeze

    module_function

    def gradient(colour)
      "background-image:linear-gradient(#{colour}, #{colour}) !important;"
    end

    # [selector, declarations] pairs for the dark-mode media query.
    def rules
      BACKGROUNDS.map { |selector, colour| [selector, gradient(colour)] } + COLOURS.to_a
    end
  end
end
