"""Live isolation test using AWS CLI; creates SELECT 1 results, no source data reads.

Run with credentials allowed to assume the consumer roles:
python tests/athena_isolation.py --account ACCOUNT --bucket RESULTS_BUCKET
Temporary role credentials stay in memory and are never printed or saved.
"""

import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--account', required=True)
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--region', default='us-east-1')
    parser.add_argument('--prefix', default='lfmesh-dev')
    args = parser.parse_args()
    checks = 0

    def call(arguments, env=None, denied=False):
        nonlocal checks
        result = subprocess.run(
            ['aws', *arguments, '--region', args.region, '--output', 'json', '--no-cli-pager'],
            env=env, capture_output=True, text=True, timeout=60,
        )
        if denied:
            assert result.returncode != 0, f'Unexpected permission: {arguments[:2]}'
            assert 'AccessDenied' in result.stderr or '(403)' in result.stderr, result.stderr
            checks += 1
            print(f'PASS denied: {arguments[0]} {arguments[1]}', flush=True)
            return None
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    sessions = {}
    queries = {}
    for persona in ('bi', 'auditoria'):
        creds = call(['sts', 'assume-role', '--role-arn',
                      f'arn:aws:iam::{args.account}:role/{args.prefix}-consumer-{persona}',
                      '--role-session-name', f'isolation-test-{persona}'])['Credentials']
        env = os.environ.copy()
        env.pop('AWS_PROFILE', None)
        env.pop('AWS_DEFAULT_PROFILE', None)
        env.update(AWS_ACCESS_KEY_ID=creds['AccessKeyId'],
                   AWS_SECRET_ACCESS_KEY=creds['SecretAccessKey'],
                   AWS_SESSION_TOKEN=creds['SessionToken'])
        sessions[persona] = env
        identity = call(['sts', 'get-caller-identity'], env)
        assert f':assumed-role/{args.prefix}-consumer-{persona}/' in identity['Arn']
        print(f'Testing {identity["Arn"]}', flush=True)
        wg = f'{args.prefix}-{persona}'
        call(['athena', 'get-work-group', '--work-group', wg], env)
        call(['athena', 'list-query-executions', '--work-group', wg, '--max-results', '1'], env)
        query = call(['athena', 'start-query-execution', '--work-group', wg,
                      '--query-string', 'SELECT 1 AS isolation_test'], env)['QueryExecutionId']
        deadline = time.monotonic() + 90
        while True:
            execution = call(['athena', 'get-query-execution', '--query-execution-id', query], env)['QueryExecution']
            state = execution['Status']['State']
            if state in ('SUCCEEDED', 'FAILED', 'CANCELLED'):
                break
            if time.monotonic() > deadline:
                raise RuntimeError(f'Query timed out: {query}')
            time.sleep(2)
        assert state == 'SUCCEEDED', execution['Status']
        call(['athena', 'get-query-results', '--query-execution-id', query], env)
        output = urlparse(execution['ResultConfiguration']['OutputLocation'])
        key = output.path.lstrip('/')
        assert output.netloc == args.bucket and key.startswith(f'{persona}/')
        queries[persona] = (query, key)
        call(['s3api', 'list-objects-v2', '--bucket', args.bucket,
              '--prefix', f'{persona}/', '--max-keys', '1'], env)
        with tempfile.TemporaryDirectory() as tmp:
            call(['s3api', 'get-object', '--bucket', args.bucket, '--key', key,
                  str(Path(tmp) / 'own.csv')], env)
        checks += 1
        print(f'PASS {persona}: own workgroup, query, results and S3 prefix ({query})', flush=True)

    for persona, other in (('bi', 'auditoria'), ('auditoria', 'bi')):
        env = sessions[persona]
        wg = f'{args.prefix}-{other}'
        query, key = queries[other]
        print(f'Testing isolation: {persona} -> {other}', flush=True)
        for operation in ('get-work-group', 'list-query-executions'):
            call(['athena', operation, '--work-group', wg], env, denied=True)
        call(['athena', 'start-query-execution', '--work-group', wg,
              '--query-string', 'SELECT 1 AS isolation_test'], env, denied=True)
        for operation in ('get-query-execution', 'get-query-results'):
            call(['athena', operation, '--query-execution-id', query], env, denied=True)
        call(['s3api', 'list-objects-v2', '--bucket', args.bucket,
              '--prefix', f'{other}/', '--max-keys', '1'], env, denied=True)
        with tempfile.TemporaryDirectory() as tmp:
            call(['s3api', 'get-object', '--bucket', args.bucket, '--key', key,
                  str(Path(tmp) / 'forbidden.csv')], env, denied=True)
            payload = Path(tmp) / 'synthetic.txt'
            payload.write_text('Synthetic Athena isolation test. No business data.\n', encoding='utf-8')
            call(['s3api', 'put-object', '--bucket', args.bucket,
                  '--key', f'{other}/isolation-denied-{query}.txt', '--body', str(payload)], env, denied=True)
    print(f'PASS: {checks} checks; SELECT 1 results retained as test evidence.', flush=True)


if __name__ == '__main__':
    main()
