#!/usr/bin/env python3
"""StevensED signing PKI: issue certificates and CRLs with keys held in Oracle Cloud Vault (HSM).

Private keys never leave the Vault. This script builds each to-be-signed structure locally,
sends only its digest to the Vault Sign API, and assembles the result. Output is public material only.

Usage: issue.py <command> [--out DIR]
  commands: root | intermediate | leaf | crls | all | verify
Environment: OCI_CLI_PROFILE (default "stevensed", session-token profile), VAULT_* as below.
"""
import argparse, base64, datetime as dt, hashlib, os, secrets, sys
from pathlib import Path

import oci
from asn1crypto import core, crl, keys, pem, x509

CRYPTO = os.environ.get('VAULT_CRYPTO_ENDPOINT', 'https://efvqprazaaen6-crypto.kms.us-phoenix-1.oraclecloud.com')
MGMT = os.environ.get('VAULT_MGMT_ENDPOINT', 'https://efvqprazaaen6-management.kms.us-phoenix-1.oraclecloud.com')
PKI = 'http://pki.stevensed.org'
UTC = dt.timezone.utc
NOW = dt.datetime.now(UTC).replace(microsecond=0)

KEYS = {
    'root': 'stevensed-root-ca',
    'intermediate': 'stevensed-document-signing-ca',
    'leaf': 'stevensed-agreements-signing',
}
NAMES = {
    'root': {'country_name': 'US', 'organization_name': 'StevensED LLC', 'common_name': 'StevensED Root CA'},
    'intermediate': {'country_name': 'US', 'organization_name': 'StevensED LLC',
                     'common_name': 'StevensED Document Signing CA'},
    'leaf': {'country_name': 'US', 'state_or_province_name': 'Utah', 'locality_name': 'Sandy',
             'organization_name': 'StevensED LLC',
             'organizational_unit_name': 'Office of Legal Operations and Institutional Compliance',
             'common_name': 'StevensED Agreements'},
}


def oci_clients():
    profile = os.environ.get('OCI_CLI_PROFILE', 'stevensed')
    cfg = oci.config.from_file(profile_name=profile)
    token = Path(os.path.expanduser(cfg['security_token_file'])).read_text().strip()
    signer = oci.auth.signers.SecurityTokenSigner(token, oci.signer.load_private_key_from_file(cfg['key_file']))
    mgmt = oci.key_management.KmsManagementClient(cfg, service_endpoint=MGMT, signer=signer)
    crypto = oci.key_management.KmsCryptoClient(cfg, service_endpoint=CRYPTO, signer=signer)
    return cfg, mgmt, crypto


class VaultKey:
    def __init__(self, cfg, mgmt, crypto, name):
        keys_ = oci.pagination.list_call_get_all_results(mgmt.list_keys, cfg['tenancy']).data
        key = next(k for k in keys_ if k.display_name == name and k.lifecycle_state == 'ENABLED')
        self.key_id = key.id
        detail = mgmt.get_key(key.id).data
        self.version_id = detail.current_key_version
        ver = mgmt.get_key_version(key.id, self.version_id).data
        self.public_key = keys.PublicKeyInfo.load(pem.unarmor(ver.public_key.encode())[2])
        self.algorithm = detail.key_shape.algorithm  # 'ECDSA' or 'RSA'
        self.crypto = crypto

    @property
    def sig_alg(self):
        return 'sha384_ecdsa' if self.algorithm == 'ECDSA' else 'sha256_rsa'

    def sign(self, tbs: bytes) -> bytes:
        if self.algorithm == 'ECDSA':
            digest, alg = hashlib.sha384(tbs).digest(), 'ECDSA_SHA_384'
        else:
            digest, alg = hashlib.sha256(tbs).digest(), 'SHA_256_RSA_PKCS1_V1_5'
        details = oci.key_management.models.SignDataDetails(
            message=base64.b64encode(digest).decode(), key_id=self.key_id, key_version_id=self.version_id,
            signing_algorithm=alg, message_type='DIGEST')
        return base64.b64decode(self.crypto.sign(details).data.signature)

    def ski(self) -> bytes:
        return hashlib.sha1(self.public_key['public_key'].contents[1:] if self.algorithm == 'ECDSA'
                            else self.public_key['public_key'].contents[1:]).digest()


def gn_uri(url):
    return x509.GeneralName(name='uniform_resource_identifier', value=url)


def name(kind):
    return x509.Name.build(NAMES[kind])


def ext(id_, value, critical=False):
    return {'extn_id': id_, 'critical': critical, 'extn_value': value}


def build_cert(subject_kind, subject_key, issuer_kind, issuer_key, years, extensions):
    tbs = x509.TbsCertificate({
        'version': 'v3',
        'serial_number': secrets.randbits(127) | (1 << 126),
        'signature': {'algorithm': issuer_key.sig_alg},
        'issuer': name(issuer_kind),
        'validity': {'not_before': x509.Time({'utc_time': NOW}),
                     'not_after': x509.Time({'general_time' if NOW.year + years >= 2050 else 'utc_time':
                                             NOW.replace(year=NOW.year + years)})},
        'subject': name(subject_kind),
        'subject_public_key_info': subject_key.public_key,
        'extensions': extensions,
    })
    sig = issuer_key.sign(tbs.dump())
    return x509.Certificate({'tbs_certificate': tbs, 'signature_algorithm': {'algorithm': issuer_key.sig_alg},
                             'signature_value': sig})


def common_exts(subject_key, issuer_key, self_signed=False):
    out = [ext('key_identifier', subject_key.ski())]
    if not self_signed:
        out.append(ext('authority_key_identifier', {'key_identifier': issuer_key.ski()}))
    return out


def write(out, filename, cert_or_crl, kind='CERTIFICATE'):
    der = cert_or_crl.dump()
    (out / filename).write_bytes(der)
    (out / (filename + '.pem')).write_bytes(pem.armor(kind, der))
    print(f'wrote {filename} ({len(der)} bytes) sha256={hashlib.sha256(der).hexdigest()}')


def load(out, filename):
    return x509.Certificate.load((out / filename).read_bytes())


def cmd_root(out, k):
    exts = common_exts(k['root'], k['root'], self_signed=True) + [
        ext('basic_constraints', {'ca': True}, critical=True),
        ext('key_usage', {'key_cert_sign', 'crl_sign'}, critical=True),
    ]
    write(out, 'root-ca.crt', build_cert('root', k['root'], 'root', k['root'], 20, exts))


def cmd_intermediate(out, k):
    exts = common_exts(k['intermediate'], k['root']) + [
        ext('basic_constraints', {'ca': True, 'path_len_constraint': 0}, critical=True),
        ext('key_usage', {'key_cert_sign', 'crl_sign'}, critical=True),
        ext('crl_distribution_points', [{'distribution_point': {'full_name': [
            gn_uri(f'{PKI}/root-ca.crl')]}}]),
        ext('authority_information_access', [{'access_method': 'ca_issuers', 'access_location':
                                              gn_uri(f'{PKI}/root-ca.crt')}]),
    ]
    write(out, 'document-signing-ca.crt', build_cert('intermediate', k['intermediate'], 'root', k['root'], 10, exts))


def cmd_leaf(out, k):
    exts = common_exts(k['leaf'], k['intermediate']) + [
        ext('basic_constraints', {'ca': False}, critical=True),
        ext('key_usage', {'digital_signature', 'non_repudiation'}, critical=True),
        ext('extended_key_usage', ['1.3.6.1.5.5.7.3.36', '1.3.6.1.4.1.311.10.3.12', 'email_protection']),
        ext('subject_alt_name', [x509.GeneralName(name='rfc822_name', value='legal@stevensed.org')]),
        ext('crl_distribution_points', [{'distribution_point': {'full_name': [
            gn_uri(f'{PKI}/document-signing-ca.crl')]}}]),
        ext('authority_information_access', [{'access_method': 'ca_issuers', 'access_location':
                                              gn_uri(f'{PKI}/document-signing-ca.crt')}]),
    ]
    write(out, 'stevensed-agreements.crt', build_cert('leaf', k['leaf'], 'intermediate', k['intermediate'], 3, exts))


def build_crl(issuer_kind, issuer_key, number, days=365):
    tbs = crl.TbsCertList({
        'version': 'v2',
        'signature': {'algorithm': issuer_key.sig_alg},
        'issuer': name(issuer_kind),
        'this_update': x509.Time({'utc_time': NOW}),
        'next_update': x509.Time({'utc_time': NOW + dt.timedelta(days=days)}),
        'crl_extensions': [
            {'extn_id': 'authority_key_identifier', 'critical': False,
             'extn_value': {'key_identifier': issuer_key.ski()}},
            {'extn_id': 'crl_number', 'critical': False, 'extn_value': number},
        ],
    })
    sig = issuer_key.sign(tbs.dump())
    return crl.CertificateList({'tbs_cert_list': tbs, 'signature_algorithm': {'algorithm': issuer_key.sig_alg},
                                'signature': sig})


def cmd_crls(out, k):
    number = int(NOW.strftime('%Y%m%d%H%M'))
    write(out, 'root-ca.crl', build_crl('root', k['root'], number), 'X509 CRL')
    write(out, 'document-signing-ca.crl', build_crl('intermediate', k['intermediate'], number), 'X509 CRL')


def cmd_verify(out, _k=None):
    from cryptography import x509 as cx
    root = cx.load_der_x509_certificate((out / 'root-ca.crt').read_bytes())
    inter = cx.load_der_x509_certificate((out / 'document-signing-ca.crt').read_bytes())
    leaf = cx.load_der_x509_certificate((out / 'stevensed-agreements.crt').read_bytes())
    root.verify_directly_issued_by(root)
    inter.verify_directly_issued_by(root)
    leaf.verify_directly_issued_by(inter)
    for f, issuer in (('root-ca.crl', root), ('document-signing-ca.crl', inter)):
        c = cx.load_der_x509_crl((out / f).read_bytes())
        assert c.is_signature_valid(issuer.public_key()), f
    for c in (root, inter, leaf):
        print(f'{c.subject.rfc4514_string()} | {c.not_valid_before_utc:%Y-%m-%d} to {c.not_valid_after_utc:%Y-%m-%d}'
              f' | sha256 {c.fingerprint(__import__("cryptography.hazmat.primitives.hashes", fromlist=["SHA256"]).SHA256()).hex()}')
    print('chain and CRL signatures verify')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['root', 'intermediate', 'leaf', 'crls', 'all', 'verify'])
    p.add_argument('--out', default=str(Path(__file__).resolve().parent.parent.parent / 'public' / 'pki-files'))
    a = p.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    if a.command == 'verify':
        return cmd_verify(out)
    cfg, mgmt, crypto = oci_clients()
    k = {kind: VaultKey(cfg, mgmt, crypto, n) for kind, n in KEYS.items()}
    steps = {'root': [cmd_root], 'intermediate': [cmd_intermediate], 'leaf': [cmd_leaf], 'crls': [cmd_crls],
             'all': [cmd_root, cmd_intermediate, cmd_leaf, cmd_crls]}[a.command]
    for s in steps:
        s(out, k)
    cmd_verify(out)


if __name__ == '__main__':
    sys.exit(main())
