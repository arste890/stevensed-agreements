# Embedding and HTML templates

This document describes two features of StevensED Agreements: placing the signing form and the template builder on StevensED websites, and creating templates from HTML. It is written for the staff who maintain stevensed.org, praxis.stevensed.org and related sites, and for the administrators of the agreements server.

Administrators can find the same examples, with the server address filled in, under Settings, Embedding.

## 1. Server configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `EMBED_ALLOWED_ORIGINS` | Sites that may show the signing form or the builder in an iframe. Separate entries with spaces or commas. A leading `*.` matches any subdomain. | `https://stevensed.org https://*.stevensed.org` |
| `GOTENBERG_URL` | Address of the Gotenberg container used to convert HTML to PDF. Already required for office documents. | none |

Entries in `EMBED_ALLOWED_ORIGINS` must be complete origins (scheme, host and optional port) without a path. Entries that do not match this form are ignored.

## 2. Signing form

### 2.1 Usage

```html
<script src="https://agreements.stevensed.org/js/form.js"></script>

<stevensed-form data-src="https://agreements.stevensed.org/s/SUBMITTER_SLUG"></stevensed-form>
```

`data-src` is either the signing link of one recipient (`/s/...`, as returned by the submissions API) or the share link of a template (`/d/...`). The element is also registered as `<docuseal-form>` for compatibility with markup written for the upstream project; both names behave the same way.

| Attribute | Meaning |
| --- | --- |
| `data-src` | Required. Signing link or share link on the same server that serves `form.js`. |
| `data-email`, `data-name`, `data-phone` | Fill in the start page of a share link. These use the parameters that the start page already accepts. |
| `data-language` | Form language, for example `en` or `es`. Passed as the existing `lang` parameter. |
| `data-height` | Height of the iframe while the documents are shown. Default `100vh`. |
| `data-min-height` | Initial height before the page reports its size. Default `480px`. |
| `data-title` | Accessible title of the iframe. Default "Signing form". |

### 2.2 Events

The element dispatches DOM events that bubble:

| Event | When | `event.detail` |
| --- | --- | --- |
| `init` | The iframe has been created. | `src` |
| `load` | The embedded page has answered the host for the first time. | `state`, and `submitter_id` and `submitter_slug` when known |
| `completed` | The recipient has completed the form, or an already completed form was opened. | `submitter_id`, `submitter_slug`, `download_url` |
| `declined` | The recipient has declined to sign. | `submitter_id`, `submitter_slug` |

`download_url` returns a JSON list of links to the signed documents. It is valid for 40 minutes from the time the signing page was loaded and only after the recipient has completed the form.

```js
document.querySelector('stevensed-form').addEventListener('completed', (event) => {
  console.log(event.detail.submitter_id, event.detail.download_url)
})
```

### 2.3 Sizing

Short pages, such as the start page, the completion page and the declined page, report their height and the iframe grows or shrinks to fit. While the documents are shown, the signing form keeps its step panel fixed at the bottom of the window, so the iframe takes the height given in `data-height` (the full window by default) and the documents scroll inside it.

## 3. Template builder

### 3.1 Usage

```html
<script src="https://agreements.stevensed.org/js/builder.js"></script>

<stevensed-builder data-token="TOKEN_FROM_YOUR_SERVER"></stevensed-builder>
```

The element is also registered as `<docuseal-builder>` for compatibility. It dispatches `init`, `load` and `save`. The `save` event fires when the user selects Save and carries `template_id`, `name` and `fields_count`.

The token is sent to the iframe with a form POST to `/embed/builder`, so it does not appear in the iframe address, in browser history or in the referrer of later requests.

### 3.2 Token

The token is an HS256 JSON Web Token created on the StevensED web server for each page view. It must never be created in the browser.

| Claim | Meaning |
| --- | --- |
| `user_email` | Email address of the user who edits the template. The user must be active and have the admin or editor role. |
| `template_id` | Numeric id of the template. Alternatively `external_id` with the external id that was set through the API. |
| `exp` | Expiry as a Unix timestamp. Required. It may be at most one hour ahead. |
| `iat` | Issue time. Optional. When present, `exp` minus `iat` may not exceed one hour. |

The signing key is the API token of that same user, found under Settings, API. A token signed with the API token of any other user is rejected.

Ruby:

```ruby
require 'jwt'

token = JWT.encode(
  { user_email: 'editor@stevensed.org', template_id: 123, iat: Time.now.to_i, exp: Time.now.to_i + 900 },
  ENV.fetch('AGREEMENTS_API_TOKEN'),
  'HS256'
)
```

Node.js:

```js
const jwt = require('jsonwebtoken')

const token = jwt.sign(
  { user_email: 'editor@stevensed.org', template_id: 123 },
  process.env.AGREEMENTS_API_TOKEN,
  { algorithm: 'HS256', expiresIn: '15m' }
)
```

Python:

```python
import os, time, jwt

now = int(time.time())
token = jwt.encode(
    {"user_email": "editor@stevensed.org", "template_id": 123, "iat": now, "exp": now + 900},
    os.environ["AGREEMENTS_API_TOKEN"],
    algorithm="HS256",
)
```

### 3.3 What the builder session allows

A valid token creates a builder session in the browser that is separate from a normal sign-in:

1. It is stored under its own session key and does not sign the user in to the rest of the application. Opening the dashboard or settings in the same browser still asks for a sign-in.
2. It applies only to the builder page and to the requests the builder makes for that one template: saving the template, adding and replacing documents, page previews, cropping, field detection and revisions.
3. It ends when the token expires. The user then reloads the host page, which mints a new token.
4. If the browser is already signed in to the agreements server as a different user, the builder shows a message instead of mixing the two identities.

In the embedded builder the Send, Sign yourself, Preview, Preferences and Download controls are hidden, because those open pages outside the scope of the session.

## 4. Security

### 4.1 Framing

* Signing pages (`/s/...`, `/d/...` and the related start, verification, completion and declined pages) and the builder page are the only responses that may be framed by other sites. They send `Content-Security-Policy: frame-ancestors 'self'` followed by the entries of `EMBED_ALLOWED_ORIGINS`, and they omit `X-Frame-Options`.
* Every other page keeps `X-Frame-Options: SAMEORIGIN` and now also sends `frame-ancestors 'self'`.

### 4.2 Messages between the host page and the iframe

* The host scripts accept a message only when it comes from the iframe they created (`event.source`) and from the origin of the agreements server (`event.origin`).
* `form.js` refuses a `data-src` that points to another server than the one that served the script.
* The bridge inside the iframe (`/js/frame.js`) stays silent until the host page sends a `stevensed:hello` message. It checks the origin of that message against the same allow list and from then on posts only to that exact origin. Pages that are not framed do nothing.

### 4.3 Cookies

The signing form and the builder rely on the session cookie of the agreements server. Because the allowed sites and the agreements server share the registrable domain `stevensed.org`, browsers treat the iframe as same site and send the cookie. Embedding on a site outside `stevensed.org` would be subject to third party cookie restrictions in current browsers and is not supported.

### 4.4 Tokens

* Keep API tokens on the server, for example in an environment variable of the website backend.
* Use short lifetimes. Fifteen minutes is enough for a page view; the server rejects more than one hour.
* Rotate a user's API token under Settings, API if it may have been exposed. Rotation also invalidates all builder tokens signed with it.

## 5. HTML templates

### 5.1 API

```shell
curl --location 'https://agreements.stevensed.org/api/templates/html' \
     --header 'X-Auth-Token: API_TOKEN' \
     --header 'Content-Type: application/json' \
     --data-raw '{
       "name": "Enrollment agreement",
       "size": "Letter",
       "html": "<h1>Enrollment agreement</h1><p>Parent name: <text-field name=\"Parent name\" role=\"Parent\"></text-field></p><p><signature-field name=\"Parent signature\" role=\"Parent\"></signature-field></p>"
     }'
```

| Parameter | Meaning |
| --- | --- |
| `html` | Required. The document HTML, up to 2 MB. |
| `html_header`, `html_footer` | Optional HTML repeated at the top and bottom of every page. The page margins grow to one inch to make room. Field tags are not supported here. |
| `name` | Template name. Defaults to the HTML `<title>`, then "HTML template". |
| `size` | `Letter`, `Legal`, `A4` or `A5`. Without a size, the form is Letter for accounts in a US time zone and A4 otherwise. Margins are half an inch. |
| `folder_name` | Folder for the template. |
| `external_id` | External id, for example to address the template in a builder token. |

The response has the same form as `GET /api/templates/:id`. Errors return status 422 with an `error` message. The API token must belong to an admin or editor.

### 5.2 From the application

Admins and editors can choose Create, then "Create a template from HTML", or use the link below the upload area on an empty dashboard. The form accepts the same HTML, header, footer and paper size, and opens the builder when the template has been created, so the fields can be checked and adjusted.

### 5.3 Field tags

```html
<text-field name="Full name" role="Parent" required="true" style="width: 200px; height: 20px"></text-field>
<signature-field name="Parent signature" role="Parent"></signature-field>
<initials-field role="Parent"></initials-field>
<date-field name="Date signed" role="Parent"></date-field>
<checkbox-field name="Photo consent" role="Parent" required="false"></checkbox-field>
```

| Attribute | Meaning |
| --- | --- |
| `name` | Field name. Defaults to the type and a number, for example "Text 2". |
| `role` | Recipient role. Each distinct role becomes a recipient, in order of first appearance. Tags without a role belong to the first recipient ("First Party" when no tag has a role). |
| `required` | `true` or `false`. Fields are required by default, except checkboxes. |
| `style` | Inline CSS for the box. `width` and `height` set its size. Other declarations, such as margins or `display: block`, are applied as written. |

Default sizes in CSS pixels: text 200 by 24, signature 220 by 60, initials 80 by 40, date 120 by 24, checkbox 18 by 18.

### 5.4 How field positions are found

Each tag is replaced with an empty inline box: an underline for most types and a border for checkboxes. The document is then converted twice by Chromium in Gotenberg with the same layout. In the first conversion every box carries two very small markers, one in its top left corner and one in its bottom right corner. The server reads the positions of these markers with PDFium and turns them into field areas. The second conversion, without markers, is stored as the template document, so no marker text remains in the PDF that recipients sign.

If a marker cannot be found, the request fails with a message naming the field, and no template is created. This happens when a tag is hidden with CSS, clipped by `overflow: hidden`, or split across a page break. Keep each field on one page, for example with `break-inside: avoid` on its container.

### 5.5 Sanitizing

Before conversion the HTML is cleaned on the server:

* Scripts, `noscript`, frames, plugins (`object`, `embed`, `applet`), forms and form controls, media elements, `link`, `meta` and `base` are removed, as are SVG `use`, `foreignObject` and animation elements.
* Event handler attributes (`onclick` and similar) are removed.
* Resource references are kept only when they are inline `data:` URLs for images or fonts. This applies to `src` and `href` attributes, CSS `url()`, `image-set()` and `@import`. Links in `<a href>` may use `http`, `https`, `mailto` and `tel`; they do not cause a request during conversion.

Images and fonts therefore need to be embedded as `data:` URLs. Gotenberg already runs Chromium with JavaScript disabled. As an additional safeguard we recommend starting Gotenberg with a Chromium deny list that blocks every network address, for example `--chromium-deny-list=^https?://.*`, so that the converter cannot reach the private network even if a reference were missed. Confirm the setting against the Gotenberg version in use before deploying it.

### 5.6 Limits

* At most 300 field tags per document.
* Only the five field types above. Other field types, such as radio groups or file uploads, can be added afterwards in the builder.
* One document per template. Updating the document of an existing template from HTML is not offered; create a new template instead, or replace the document in the builder.

## 6. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| The iframe shows a browser message that the page refused to connect. | The host site is not in `EMBED_ALLOWED_ORIGINS`, or the page inside the iframe navigated outside the signing pages. |
| No `load` or `completed` events. | The host page origin is not in `EMBED_ALLOWED_ORIGINS`, so the bridge does not answer. Check the browser console of the host page. |
| The builder shows "The access token is invalid or has expired". | The token is older than its `exp`, lives longer than one hour, was signed with another user's API token, names a viewer or client, or names a template outside the user's account. The server log records the reason. |
| HTML conversion fails. | `GOTENBERG_URL` is not set or the container is unreachable. |
