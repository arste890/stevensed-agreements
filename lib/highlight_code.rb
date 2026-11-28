# frozen_string_literal: true

module HighlightCode
  module_function

  def call(code, lexer, theme: 'base16.light')
    require 'rouge/themes/base16' unless Rouge::Theme.registry[theme]

    formatter = Rouge::Formatters::HTMLInline.new(theme)
    lexer = Rouge::Lexers.const_get(lexer.to_sym).new
    formatted_code = formatter.format(lexer.lex(code))
    formatted_code = formatted_code.gsub('background-color: #181818', '') if theme == 'base16.dark'
    formatted_code = lighten_for_navy(formatted_code) if theme == 'base16.dark'
    formatted_code
  end

  # StevensED: code blocks sit on the navy mockup background; these base16 dark colours were below WCAG AA there.
  NAVY_SAFE_COLOURS = {
    '#585858' => '#aeb7cb',
    '#ba8baf' => '#dcaad2',
    '#7cafc2' => '#a6d0e2',
    '#a16946' => '#d9a27a',
    '#dc9656' => '#e8b383'
  }.freeze

  def lighten_for_navy(html)
    NAVY_SAFE_COLOURS.reduce(html) { |acc, (from, to)| acc.gsub(/#{from}\b/i, to) }
  end
end
