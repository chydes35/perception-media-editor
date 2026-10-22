#!/usr/bin/env python3
"""Validate an opt-in private manifest and hash only opaque, standalone copies.

No EXIF extraction, original-media access, rendering, uploads or file writes.
Exit 0: integrity checked (or template structure checked); 1: rejected; 3: no data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat

REPO = Path(__file__).resolve().parents[1]
ID = re.compile(r'S5-[0-9]{4}')
DIGEST = re.compile(r'[0-9a-f]{64}')
FORMATS = {'RW2', 'JPG', 'JPEG'}
PERMISSIONS = {'copied_from_original', 'provenance_recorded_locally', 'read_copy', 'hash_copy',
               'inspect_safe_metadata', 'render_copy', 'export_derivatives', 'generate_masks',
               'publish_media', 'publish_metadata_or_hashes'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def outside_repo(path):
    return not path.resolve().is_relative_to(REPO)


def check_record(item, measured):
    require(isinstance(item, dict), 'invalid fixture record')
    require(isinstance(item.get('fixture_id'), str) and ID.fullmatch(item['fixture_id']), 'invalid opaque fixture ID')
    require(item.get('format') in FORMATS, 'unsupported fixture format')
    require(isinstance(item.get('scenario'), str) and bool(item['scenario']), 'scenario required')
    for key in ('shoot_id', 'capture_pair_id'):
        value = item.get(key)
        require(value is None or (isinstance(value, str) and re.fullmatch(r'(SHOOT|PAIR)-[0-9]{4}', value)), 'invalid opaque grouping ID')
    permissions = item.get('permissions')
    require(isinstance(permissions, dict) and set(permissions) == PERMISSIONS, 'exact process permissions required')
    require(all(type(value) is bool for value in permissions.values()), 'permissions must be Boolean')
    require(not permissions['publish_media'] and not permissions['publish_metadata_or_hashes'], 'private publication forbidden')
    if measured:
        require(all(permissions[key] for key in ('copied_from_original', 'provenance_recorded_locally', 'read_copy', 'hash_copy')), 'copy/hash permission or provenance missing')
    camera = item.get('camera')
    require(isinstance(camera, dict), 'camera verification fields required')
    for field in ('model', 'firmware'):
        verified = camera.get(field + '_verified')
        require(type(verified) is bool, 'camera verification must be explicit')
        value = camera.get(field)
        require((verified and isinstance(value, str) and bool(value)) or (not verified and value is None), 'unverified camera fields must be null')
        if verified:
            require(camera.get('verification_method') not in (None, '', 'not_verified'), 'camera evidence method required')
    exposure = item.get('exposure')
    require(isinstance(exposure, dict) and 'verification_method' in exposure, 'exposure verification required')
    for key in ('iso', 'shutter_seconds', 'aperture_f_number'):
        value = exposure.get(key)
        require(value is None or (type(value) in (int, float) and value > 0), 'invalid exposure value')
    if any(exposure.get(key) is not None for key in ('iso', 'shutter_seconds', 'aperture_f_number', 'exposure_mode', 'white_balance_mode')):
        require(exposure['verification_method'] not in (None, '', 'not_verified'), 'exposure evidence method required')
    mode = item.get('capture_mode')
    require(isinstance(mode, dict) and isinstance(mode.get('uncertainty'), str) and bool(mode['uncertainty']), 'capture-mode uncertainty required')
    require(mode.get('value') is None or mode.get('verification_method') not in (None, '', 'not_verified'), 'capture-mode evidence required')
    if measured:
        require(isinstance(item.get('sha256'), str) and DIGEST.fullmatch(item['sha256']), 'copy SHA-256 required')
        require(type(item.get('byte_count')) is int and item['byte_count'] > 0, 'positive byte count required')
    original = item.get('original_sha256')
    require(original is None or (isinstance(original, str) and DIGEST.fullmatch(original)), 'invalid recorded original hash')


def hash_copy(directory_fd, item):
    # Basename is derived, never accepted as a user path. O_NONBLOCK avoids FIFO hangs.
    name = item['fixture_id'] + '.' + item['format']
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, 'copy must be a standalone regular file')
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
        after = os.fstat(source.fileno())
    require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'copy changed during validation')
    require(after.st_size == item['byte_count'] and digest == item['sha256'], 'copy integrity mismatch')
    original = item.get('original_sha256')
    require(original is None or original == digest, 'recorded original hash mismatch')
    original_status = 'PASS' if original else 'NOT VERIFIED'
    model_status = 'PASS' if item['camera']['model_verified'] else 'NOT VERIFIED'
    print(f"{item['fixture_id']}: copy_hash=PASS recorded_original_hash={original_status} camera_evidence={model_status}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--copies', type=Path)
    parser.add_argument('--check-template', action='store_true', help='structure only; never a dataset pass')
    args = parser.parse_args()
    try:
        require(args.check_template or outside_repo(args.manifest), 'populated manifest must be outside repository')
        with args.manifest.open() as source:
            data = json.load(source)
        require(data.get('schema_id') == 'PME-MPKB-M0-FIXTURES-2' and data.get('schema_version') == 2, 'unsupported manifest schema')
        require(data.get('privacy') == {'private_manifest': True, 'copied_media_only': True, 'no_gps_faces_personal_names_in_reports': True, 'never_commit_media_or_populated_manifest': True}, 'privacy rules required')
        fixtures = data.get('fixtures')
        require(isinstance(fixtures, list), 'fixtures array required')
        if args.check_template:
            require(data.get('status') == 'TEMPLATE_ONLY_NOT_POPULATED' and not fixtures and not data.get('measurements'), 'template must remain empty')
            check_record(data.get('example_not_measured'), measured=False)
            print('PASS template structure; dataset and photographic gates NOT VERIFIED')
            return 0
        require(args.copies is not None and outside_repo(args.copies), 'copies must be outside repository')
        if not fixtures:
            print('NOT VERIFIED: empty fixture dataset')
            return 3
        require(data.get('status') == 'LOCAL_PRIVATE', 'local private status required')
        for item in fixtures:
            check_record(item, measured=True)
        require(len({item['fixture_id'] for item in fixtures}) == len(fixtures), 'duplicate fixture IDs')
        directory_fd = os.open(args.copies, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for item in fixtures:
                hash_copy(directory_fd, item)
        finally:
            os.close(directory_fd)
        print(f'PASS copy integrity: {len(fixtures)} records; originals were not opened. Scenario coverage, consent and photographic acceptance require review.')
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        # Do not print exception text: it can contain private names, JSON or paths.
        print('FAIL: manifest, permission/provenance or copy integrity check rejected; review private inputs locally.')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
