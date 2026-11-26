# frozen_string_literal: true

describe 'HTML templates' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }

  let(:html) do
    <<~HTML
      <html>
        <head><title>Enrollment agreement</title></head>
        <body>
          <h1 onclick="alert(1)">Enrollment agreement</h1>
          <script>document.write('removed')</script>
          <img src="https://example.com/tracker.png">
          <p>Parent name: <text-field name="Parent name" role="Parent" style="width: 200px; height: 20px"></text-field></p>
          <p><signature-field name="Parent signature" role="Parent"></signature-field></p>
          <p><checkbox-field name="Photo consent" role="Student"></checkbox-field></p>
        </body>
      </html>
    HTML
  end

  let(:markers) do
    [
      ['QZ0SZ', 100, 700], ['QZ0EZ', 240, 686],
      ['QZ1SZ', 100, 600], ['QZ1EZ', 260, 560],
      ['QZ2SZ', 100, 500], ['QZ2EZ', 104, 488]
    ]
  end

  describe 'POST /api/templates/html' do
    it 'creates a template with fields from the field tags' do
      stub_gotenberg_html_conversion(markers)

      post '/api/templates/html', headers: { 'x-auth-token': author.access_token.token },
                                  params: { html:, size: 'Letter', external_id: 'enrollment' }, as: :json

      expect(response).to have_http_status(:ok)

      template = Template.find(response.parsed_body['id'])

      expect(template.name).to eq('Enrollment agreement')
      expect(template.external_id).to eq('enrollment')
      expect(template.source).to eq('api')
      expect(template.submitters.pluck('name')).to eq(%w[Parent Student])
      expect(template.documents.size).to eq(1)
      expect(template.schema.first['attachment_uuid']).to eq(template.documents.first.uuid)

      expect(template.fields.pluck('type')).to eq(%w[text signature checkbox])
      expect(template.fields.pluck('name')).to eq(['Parent name', 'Parent signature', 'Photo consent'])
      expect(template.fields.pluck('required')).to eq([true, true, false])

      student_uuid = template.submitters.find { |s| s['name'] == 'Student' }['uuid']
      expect(template.fields.last['submitter_uuid']).to eq(student_uuid)

      area = template.fields.first['areas'].first

      expect(area['page']).to eq(0)
      expect(area['attachment_uuid']).to eq(template.documents.first.uuid)
      expect(area['x']).to be_within(0.01).of(100 / 612.0)
      expect(area['y']).to be_within(0.015).of((792 - 704) / 792.0)
      expect(area['w']).to be_within(0.03).of((240 + 15 - 100) / 612.0)
      expect(area['h']).to be > 0
    end

    it 'sends sanitized HTML and the paper size to the converter' do
      stub_gotenberg_html_conversion(markers)

      post '/api/templates/html', headers: { 'x-auth-token': author.access_token.token },
                                  params: { html:, size: 'A4' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(Stevensed::Gotenberg).to have_received(:html_to_pdf).twice
      expect(Stevensed::Gotenberg).to have_received(:html_to_pdf)
        .with(satisfy { |value| %w[<script onclick tracker].none? { |text| value.include?(text) } },
              hash_including(paper_width: 8.27, paper_height: 11.69)).twice
    end

    it 'returns an error when a field position is not found' do
      stub_gotenberg_html_conversion(markers.first(2))

      post '/api/templates/html', headers: { 'x-auth-token': author.access_token.token },
                                  params: { html: }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('field 2')
      expect(Template.count).to eq(0)
    end

    it 'returns an error for an unknown paper size' do
      post '/api/templates/html', headers: { 'x-auth-token': author.access_token.token },
                                  params: { html:, size: 'Tabloid' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'requires html' do
      post '/api/templates/html', headers: { 'x-auth-token': author.access_token.token }, params: {}, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('html is required.')
    end

    it 'does not allow the viewer role' do
      viewer = create(:user, account:, role: User::VIEWER_ROLE)

      post '/api/templates/html', headers: { 'x-auth-token': viewer.access_token.token },
                                  params: { html: }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /templates/html' do
    it 'creates a template from pasted HTML and opens the builder' do
      stub_gotenberg_html_conversion(markers)
      sign_in(author)

      post templates_html_path, params: { html:, name: 'Pasted agreement', size: 'letter' }

      template = Template.last

      expect(response).to redirect_to(edit_template_path(template))
      expect(template.name).to eq('Pasted agreement')
      expect(template.fields.size).to eq(3)
    end
  end
end
