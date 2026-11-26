# frozen_string_literal: true

# StevensED: pre-deploy smoke pass over the routes an admin or signer can reach.
# Usage (in the app container): bin/rails runner tools/smoke/smoke.rb
#   SMOKE_SIGNER_SLUGS=slug1,slug2  signing links of test envelopes to check (signer pages and downloads)
#   SMOKE_HOST                      host header (default agreements.stevensed.org)
#
# Requests run in-process as the first admin (Warden test login); nothing is sent over the network. GET only, so
# no records are changed, except that opening a signing link records a "view" event on that test envelope.
# Reports every status other than 200/302/304 and any user-visible "DocuSeal" or docuseal.com text outside /legal.

require 'warden'

include Warden::Test::Helpers # rubocop:disable Style/MixinUsage
Warden.test_mode!

Rails.logger.level = :warn
HOST = ENV.fetch('SMOKE_HOST', 'agreements.stevensed.org')
ALLOWED_BRANDING = %r{/legal\b}
BRANDING = /docuseal\.com|console\.docuseal|\bDocuSeal\b/

account = Account.order(:id).first
admin = account.users.where(role: User::ADMIN_ROLE).order(:id).first
template = Template.where(account:, archived_at: nil).order(:id).last
submission = Submission.where(account:).where.not(completed_at: nil).order(:id).last
submitter = submission&.submitters&.first

session = ActionDispatch::Integration::Session.new(Rails.application)
session.host = HOST
session.https!

def visible_text(html)
  html.to_s.gsub(%r{<script\b.*?</script>}m, ' ').gsub(%r{<style\b.*?</style>}m, ' ')
      .gsub(/<!--.*?-->/m, ' ')
end

paths = Rails.application.routes.routes.filter_map do |route|
  next unless route.verb.to_s.include?('GET')

  path = route.path.spec.to_s.sub('(.:format)', '')
  next if path.include?(':') || path.include?('*') || path.match?(%r{\A/(rails|cable|sidekiq|assets|packs|up)\b})
  next if path.match?(%r{\A/(logout|sign_out|users/sign_out|auth)\b}) # side effects: sign-out, SSO redirects

  path
end.uniq

if template
  paths += ["/templates/#{template.id}", "/templates/#{template.id}/edit", "/templates/#{template.id}/preferences",
            "/templates/#{template.id}/submissions/new", "/templates/#{template.id}/code_modal",
            "/templates/#{template.id}/form", "/templates/#{template.id}/share_link"]
end
paths += ["/submissions/#{submission.id}", "/submissions/#{submission.id}/events"] if submission
paths += %w[/manifest /manifest.json /legal /accessibility /does-not-exist]

results = []

login_as(admin, scope: :user)

paths.uniq.sort.each do |path|
  session.get(path)
  status = session.response.status
  branded = path.match?(ALLOWED_BRANDING) ? nil : visible_text(session.response.body)[BRANDING]
  results << [path, status, branded] if ![200, 302, 304].include?(status) || branded
rescue StandardError => e
  results << [path, "ERROR #{e.class}: #{e.message[0, 120]}", nil]
end

logout(:user)

slugs = ENV.fetch('SMOKE_SIGNER_SLUGS', '').split(',').map(&:strip).compact_blank
slugs.each do |slug|
  %W[/s/#{slug} /s/#{slug}/documents /s/#{slug}/documents?kind=documents /s/#{slug}/documents?kind=audit
     /s/#{slug}/completed].each do |path|
    session.get(path)
    status = session.response.status
    branded = visible_text(session.response.body)[BRANDING]
    results << [path, status, branded] if ![200, 302, 304, 404].include?(status) || branded
  rescue StandardError => e
    results << [path, "ERROR #{e.class}: #{e.message[0, 120]}", nil]
  end
end

puts "Checked #{paths.uniq.size} admin paths and #{slugs.size} signing links " \
     "(template #{template&.id}, submission #{submission&.id}, submitter #{submitter&.id})."
if results.empty?
  puts 'No problems found.'
else
  results.each { |path, status, branded| puts [path, status, (branded && "branding: #{branded}")].compact.join(' | ') }
end
