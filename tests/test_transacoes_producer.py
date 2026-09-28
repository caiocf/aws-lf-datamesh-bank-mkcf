import os
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import MagicMock, patch


class ConcurrentRunsExceeded(Exception):
    pass


class ProducerTests(unittest.TestCase):
    def run_handler(self, error=None):
        boto = MagicMock()
        glue = boto.client.return_value
        glue.exceptions.ConcurrentRunsExceededException = ConcurrentRunsExceeded
        glue.start_workflow_run.side_effect = error
        path = Path(__file__).resolve().parents[1] / 'envs/dev/domains/transacoes/scripts/producer.py'
        with patch.dict(sys.modules, {'boto3': boto, 'kafka': MagicMock()}):
            module = runpy.run_path(str(path))
        kafka = MagicMock()
        handler = module['handler']
        handler.__globals__['get_producer'] = lambda: kafka
        with patch.dict(os.environ, {'TOPIC_NAME': 'test', 'NUM_TRANSACTIONS': '2',
                                     'GLUE_WORKFLOW_NAME': 'test-pipeline'}), patch('time.sleep'):
            result = handler({}, None)
        self.assertEqual(kafka.send.call_count, 2)
        kafka.flush.assert_called_once()
        glue.start_workflow_run.assert_called_once_with(Name='test-pipeline')
        self.assertEqual(result['statusCode'], 200)
        return result

    def test_starts_after_publishing(self):
        self.assertIn('disparado', self.run_handler()['body'])

    def test_concurrency_is_success_after_publishing(self):
        self.assertIn('ja em andamento', self.run_handler(ConcurrentRunsExceeded())['body'])

    def test_other_failures_are_not_hidden(self):
        with self.assertRaisesRegex(RuntimeError, 'AccessDenied'):
            self.run_handler(RuntimeError('AccessDenied'))


if __name__ == '__main__':
    unittest.main()
