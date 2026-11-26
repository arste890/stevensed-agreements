"""StevensED Agreements signing service.

Signs a SHA-256 digest with the StevensED Agreements key in Oracle Cloud Vault (HSM, not exportable),
using the VM's instance principal. Reachable only on the private Docker network and only with the
shared token. Returns the raw RSA PKCS#1 v1.5 signature (base64).
"""
import base64, hmac, json, logging, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import oci

KEY_ID = os.environ['KEY_ID']
KEY_VERSION_ID = os.environ['KEY_VERSION_ID']
CRYPTO_ENDPOINT = os.environ['CRYPTO_ENDPOINT']
TOKEN = os.environ['SIGNER_TOKEN'].encode()
ALGORITHMS = {'sha256': ('SHA_256_RSA_PKCS1_V1_5', 32), 'sha384': ('SHA_384_RSA_PKCS1_V1_5', 48),
              'sha512': ('SHA_512_RSA_PKCS1_V1_5', 64)}

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
client = oci.key_management.KmsCryptoClient({}, service_endpoint=CRYPTO_ENDPOINT, signer=signer)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        self._send(200, {'status': 'ok'}) if self.path == '/health' else self._send(404, {'error': 'not found'})

    def do_POST(self):  # noqa: N802
        if self.path != '/sign':
            return self._send(404, {'error': 'not found'})
        if not hmac.compare_digest(self.headers.get('Authorization', '').encode(), b'Bearer ' + TOKEN):
            return self._send(401, {'error': 'unauthorized'})
        try:
            req = json.loads(self.rfile.read(min(int(self.headers.get('Content-Length', 0)), 4096)))
            alg, size = ALGORITHMS[req['algorithm'].lower()]
            digest = base64.b64decode(req['digest'])
            if len(digest) != size:
                raise ValueError('digest length')
            details = oci.key_management.models.SignDataDetails(
                message=base64.b64encode(digest).decode(), key_id=KEY_ID, key_version_id=KEY_VERSION_ID,
                signing_algorithm=alg, message_type='DIGEST')
            sig = client.sign(details).data.signature
            logging.info('signed digest alg=%s', alg)
            self._send(200, {'signature': sig})
        except (KeyError, ValueError) as e:
            self._send(400, {'error': f'bad request: {e}'})
        except oci.exceptions.ServiceError as e:
            logging.error('vault error %s %s', e.status, e.code)
            self._send(502, {'error': 'vault unavailable'})

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    ThreadingHTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
