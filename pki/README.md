# StevensED signing PKI

Public certificates and certificate revocation lists for StevensED Agreements, published at
http://pki.stevensed.org/ (and HTTPS). Private keys are generated and held in Oracle Cloud Vault
`stevensed-signing` (HSM protection, not exportable); this repository contains public material only.

| File | Subject | Key | Valid |
| --- | --- | --- | --- |
| `root-ca.crt` | StevensED Root CA | ECDSA P-384 (`stevensed-root-ca`) | 2026-11-26 to 2046-11-26 |
| `document-signing-ca.crt` | StevensED Document Signing CA | ECDSA P-384 (`stevensed-document-signing-ca`) | 2026-11-26 to 2036-11-26 |
| `stevensed-agreements.crt` | StevensED Agreements | RSA 3072 (`stevensed-agreements-signing`) | 2026-11-26 to 2029-11-26 |

Revocation lists (`root-ca.crl`, `document-signing-ca.crl`) expire one year after issue and must be reissued
before then with `tools/pki/issue.py crls` (Oracle session login required), then copied to
`/opt/docuseal/pki/public/` on the server. Issuance is performed only with the Vault Sign API.
