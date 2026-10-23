import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ConnectionSettingsTest(unittest.TestCase):
    def interpolate(self, ops, path, source='bosh.yml', variables=(), strict=False):
        arguments = ['bosh', 'interpolate', source]
        for op in ops:
            arguments.extend(['-o', op])
        for variable in variables:
            arguments.extend(['--var', variable])
        if strict:
            arguments.append('--var-errs')
        arguments.extend(['--path', path])
        return subprocess.run(arguments, cwd=REPO, capture_output=True, text=True)

    def test_ipv6_blobstore_retains_tls_and_address_brackets(self):
        result = self.interpolate(['misc/ipv6/bosh.yml'],
                                  '/instance_groups/name=bosh/properties/agent/env/bosh/blobstores/0/options/endpoint',
                                  variables=['internal_ip=2001:db8::10'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'https://[2001:db8::10]:25250')

    def test_softlayer_blobstore_keeps_tls_with_selected_addresses(self):
        for name, address in [('cpi.yml', '192.0.2.10'), ('cpi-dynamic.yml', '192.0.2.10'), ('cpi-legacy-dynamic.yml', '192.0.2.11')]:
            with self.subTest(name=name):
                result = self.interpolate(['softlayer/' + name],
                                          '/instance_groups/name=bosh/properties/agent/env/bosh/blobstores/provider=dav/options/endpoint',
                                          variables=['internal_ip=192.0.2.10', 'director_ip=192.0.2.11'])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'https://' + address + ':25250')
                ca = self.interpolate(['softlayer/' + name], '/instance_groups/name=bosh/properties/agent/env/bosh/blobstores/provider=dav/options/tls/cert/ca')
                self.assertEqual(ca.returncode, 0, ca.stderr)
                self.assertEqual(ca.stdout.strip(), '((blobstore_server_tls.ca))')
                names = self.interpolate(['softlayer/' + name], '/variables/name=blobstore_server_tls/options/alternative_names',
                                         variables=['internal_ip=192.0.2.10', 'director_ip=192.0.2.11'])
                self.assertEqual(names.returncode, 0, names.stderr)
                self.assertIn('- ' + address, names.stdout.splitlines())

    def test_cloudstack_legacy_blobstore_keeps_tls_and_ca(self):
        result = self.interpolate(['cloudstack/cpi.yml'], '/instance_groups/name=bosh/properties/agent/blobstore/options/endpoint',
                                  variables=['internal_ip=192.0.2.10'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'https://192.0.2.10:25250')
        ca = self.interpolate(['cloudstack/cpi.yml'], '/instance_groups/name=bosh/properties/agent/blobstore/options/tls/cert/ca')
        self.assertEqual(ca.returncode, 0, ca.stderr)
        self.assertEqual(ca.stdout.strip(), '((blobstore_ca.certificate))')

    def test_external_director_database_requires_ca(self):
        with tempfile.TemporaryDirectory(prefix='external-db-ops-') as directory:
            manifest = Path(directory) / 'manifest.yml'
            manifest.write_text('instance_groups:\n- name: bosh\n  jobs: []\n  properties:\n    postgres: {}\n    director:\n      db: {}\n')
            variables = ['external_db_host=db.example.invalid', 'external_db_port=5432', 'external_db_user=fixture',
                         'external_db_password=fixture', 'external_db_adapter=postgres', 'external_db_name=fixture']
            missing = self.interpolate(['misc/external-db.yml'], '/instance_groups/name=bosh/properties/director/db',
                                       source=str(manifest), variables=variables, strict=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('db_ca', missing.stderr)
            enabled = self.interpolate(['misc/external-db.yml'], '/instance_groups/name=bosh/properties/director/db/tls/enabled',
                                       source=str(manifest), variables=variables + ['db_ca=fixture-ca'], strict=True)
            self.assertEqual(enabled.returncode, 0, enabled.stderr)
            self.assertEqual(enabled.stdout.strip(), 'true')
            ca = self.interpolate(['misc/external-db.yml'], '/instance_groups/name=bosh/properties/director/db/tls/cert/ca',
                                  source=str(manifest), variables=variables + ['db_ca=fixture-ca'], strict=True)
            self.assertEqual(ca.returncode, 0, ca.stderr)
            self.assertEqual(ca.stdout.strip(), 'fixture-ca')


if __name__ == '__main__':
    unittest.main()
