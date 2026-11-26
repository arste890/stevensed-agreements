# frozen_string_literal: true

RSpec.describe Stevensed::HtmlTemplates do
  describe Stevensed::HtmlTemplates::HtmlSanitizer do
    def sanitize(html)
      described_class.call(html).to_html
    end

    it 'removes scripts, frames, forms and event handlers' do
      html = sanitize(<<~HTML)
        <p onmouseover="x()">Text</p><script>alert(1)</script><iframe src="https://example.com"></iframe>
        <form action="https://example.com"><input name="a"></form><object data="x.swf"></object>
        <a href="javascript:alert(1)">Link</a><a href="https://stevensed.org">Site</a>
      HTML

      expect(html).not_to include('<script', 'onmouseover', '<iframe', '<form', '<input', '<object', 'javascript:')
      expect(html).to include('href="https://stevensed.org"')
    end

    it 'keeps only data URLs for images and style sheets' do
      html = sanitize(<<~HTML)
        <link rel="stylesheet" href="https://example.com/a.css">
        <style>@import url("https://example.com/b.css"); body { background: url(https://example.com/c.png); }
        .logo { background: url("data:image/png;base64,AAAA"); } .x { background: \\75 rl(https://example.com/d.png) }</style>
        <img src="https://example.com/e.png"><img src="data:image/png;base64,AAAA">
        <svg><image href="http://169.254.169.254/latest"></image></svg>
        <div style="background-image: url('http://internal/f.png')">x</div>
      HTML

      expect(html).not_to include('example.com', '169.254.169.254', 'internal', '<link')
      expect(html).to include('src="data:image/png;base64,AAAA"')
      expect(html).to include('url("data:image/png;base64,AAAA")')
    end

    it 'keeps field tags and their attributes' do
      html = sanitize('<text-field name="Full name" role="Parent" required="false" style="width: 50px"></text-field>')

      expect(html).to include('<text-field name="Full name" role="Parent" required="false" style="width: 50px">')
    end
  end

  describe '.extract_fields' do
    it 'reads names, roles, required flags and sizes' do
      document = Stevensed::HtmlTemplates::HtmlSanitizer.call(<<~HTML)
        <text-field name="Full name" role="Parent" style="width: 150px; height: 18px"></text-field>
        <date-field required="false"></date-field>
        <checkbox-field required="true"></checkbox-field>
      HTML

      fields = described_class.extract_fields(document)

      expect(fields.map(&:type)).to eq(%w[text date checkbox])
      expect(fields.map(&:required)).to eq([true, false, true])
      expect(fields.first.width).to eq('150px')
      expect(fields.first.height).to eq('18px')
      expect(fields.second.width).to eq('120px')
      expect(fields.first.role).to eq('Parent')
      expect(fields.second.role).to be_nil
    end
  end
end
