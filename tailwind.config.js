module.exports = {
  future: {
    hoverOnlyWhenSupported: true
  },
  plugins: [
    require('daisyui')
  ],
  daisyui: {
    themes: [
      {
        docuseal: {
          // StevensED palette (stevensed.org brand tokens)
          'color-scheme': 'light',
          primary: '#e9e3d8',
          secondary: '#f0a7a9',
          accent: '#C13F44',
          neutral: '#2F3E68',
          'base-100': '#f7f5f1',
          'base-200': '#e9e3d8',
          'base-300': '#d8d0c1',
          'base-content': '#1f2948',
          '--rounded-btn': '1.9rem',
          '--tab-border': '2px',
          '--tab-radius': '.5rem'
        }
      }
    ]
  }
}
