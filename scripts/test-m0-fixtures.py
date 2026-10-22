#!/usr/bin/env python3
"""Synthetic checks of the local manifest validator; never loads real photography."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / 'scripts/m0-validate-fixtures.py'
TEMPLATE = ROOT / 'docs/research/mpkb-v2/m0-fixture-manifest.template.json'


class FixtureContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.copies = self.root / 'copies'
        self.copies.mkdir()
        self.media = self.copies / 'S5-0001.RW2'
        self.media.write_bytes(b'synthetic contract data, not a RAW photograph')
        self.digest = hashlib.sha256(self.media.read_bytes()).hexdigest()
        self.manifest = json.loads(TEMPLATE.read_text())
        self.manifest['status'] = 'LOCAL_PRIVATE'
        self.fixture = copy.deepcopy(self.manifest.pop('example_not_measured'))
        self.fixture.update(sha256=self.digest, original_sha256=self.digest, byte_count=self.media.stat().st_size)
        self.fixture['permissions'].update(read_copy=True, hash_copy=True, copied_from_original=True, provenance_recorded_locally=True)
        self.manifest['fixtures'] = [self.fixture]

    def run_validator(self, expected=0, template=False):
        path = self.root / 'manifest.json'
        path.write_text(json.dumps(self.manifest))
        args = ['python3', str(VALIDATOR), '--manifest', str(path)]
        args += ['--check-template'] if template else ['--copies', str(self.copies)]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn(str(self.root), result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_valid_copy_hashes_without_writing(self):
        before = self.media.stat()
        out = self.run_validator()
        self.assertIn('original_hash=PASS', out)
        self.assertEqual(self.media.read_bytes(), b'synthetic contract data, not a RAW photograph')
        self.assertEqual(self.media.stat().st_mtime_ns, before.st_mtime_ns)

    def test_changed_copy_is_rejected(self):
        self.media.write_bytes(b'changed copy')
        self.run_validator(1)

    def test_denied_read_is_rejected_before_media_access(self):
        self.fixture['permissions']['read_copy'] = False
        self.media.unlink()
        self.assertIn('permission', self.run_validator(1))

    def test_symlink_is_rejected(self):
        self.media.unlink()
        self.media.symlink_to(self.root / 'private-original.RW2')
        self.run_validator(1)

    def test_hardlink_is_rejected(self):
        import os
        os.link(self.media, self.root / 'private-original.RW2')
        self.run_validator(1)

    def test_path_in_id_is_rejected_without_disclosure(self):
        self.fixture['fixture_id'] = '../personal-name'
        self.assertNotIn('personal-name', self.run_validator(1))

    def test_empty_manifest_is_not_a_dataset_pass(self):
        self.manifest['fixtures'] = []
        self.assertIn('NOT VERIFIED', self.run_validator(3))

    def test_unknown_original_hash_is_not_reported_as_pass(self):
        self.fixture['original_sha256'] = None
        self.assertIn('original_hash=NOT VERIFIED', self.run_validator())

    def test_original_hash_mismatch_is_rejected(self):
        self.fixture['original_sha256'] = '0' * 64
        self.run_validator(1)

    def test_unverified_firmware_cannot_be_asserted(self):
        self.fixture['camera']['firmware'] = 'unknown-but-claimed'
        self.run_validator(1)

    def test_duplicate_fixture_ids_are_rejected(self):
        self.manifest['fixtures'].append(copy.deepcopy(self.fixture))
        self.run_validator(1)

    def test_manifest_and_copies_inside_repo_are_rejected(self):
        result = subprocess.run(['python3', str(VALIDATOR), '--manifest', str(TEMPLATE), '--copies', str(ROOT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)


if __name__ == '__main__':
    unittest.main()
