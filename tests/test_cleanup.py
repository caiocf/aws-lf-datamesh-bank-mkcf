import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('purge', ROOT / 'scripts/empty-lab-buckets.py')
purge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(purge)


class CleanupTests(unittest.TestCase):
    def test_versions_include_delete_markers_and_null_version(self):
        self.assertEqual(purge.version_identifiers({
            'Versions': [{'Key': 'data', 'VersionId': 'null'}],
            'DeleteMarkers': [{'Key': 'old', 'VersionId': 'v1'}],
        }), [{'Key': 'data', 'VersionId': 'null'}, {'Key': 'old', 'VersionId': 'v1'}])

    def test_partial_delete_errors_are_not_success(self):
        with patch.object(purge, 'aws', return_value={'Errors': [{'Code': 'AccessDenied'}]}):
            with self.assertRaises(purge.AwsError):
                purge.delete_batch('bucket', '123', [{'Key': 'data', 'VersionId': 'v1'}])

    def test_access_denied_head_is_not_missing_bucket(self):
        with patch.object(purge, 'aws', side_effect=purge.AwsError('(403) Forbidden')):
            with self.assertRaises(purge.AwsError):
                purge.empty_bucket('bucket', '123', 10)

    def test_wrong_account_bucket_is_rejected(self):
        with patch('sys.argv', ['purge', '--bucket', 'lfmesh-dev-riscos-bronze-999', '--execute']), \
             patch.object(purge, 'aws', return_value={'Account': '123'}), \
             patch.object(purge, 'empty_bucket') as empty:
            with self.assertRaises(SystemExit):
                purge.main()
            empty.assert_not_called()

    def test_dry_run_does_not_delete(self):
        with patch('sys.argv', ['purge', '--bucket', 'lfmesh-dev-riscos-bronze-123']), \
             patch.object(purge, 'aws', return_value={'Account': '123'}), \
             patch.object(purge, 'empty_bucket') as empty:
            purge.main()
            empty.assert_not_called()

    def test_versions_are_deleted_before_current_objects(self):
        responses = [{}, {'Versions': [{'Key': 'a', 'VersionId': 'v'}]}, {}, {}, {}, {}]
        with patch.object(purge, 'aws', side_effect=responses), \
             patch.object(purge, 'delete_batch') as delete:
            purge.empty_bucket('bucket', '123', 10)
            delete.assert_called_once_with('bucket', '123', [{'Key': 'a', 'VersionId': 'v'}])


if __name__ == '__main__':
    unittest.main()
