"""Empty only explicitly scoped lab buckets, including all S3 versions.

Uses Python's standard library and the configured AWS CLI. Does not delete the
bucket: Terraform retains ownership of resource deletion and state updates.
"""
import argparse
import json
import os
import re
import subprocess
import tempfile
import time


class AwsError(RuntimeError):
    pass


def aws(*args):
    result = subprocess.run(
        ["aws", *args, "--output", "json", "--no-cli-pager"],
        capture_output=True, text=True, encoding="utf-8",
        env={**os.environ, "PYTHONIOENCODING": "utf-8", "AWS_PAGER": ""},
        timeout=120,
    )
    if result.returncode:
        raise AwsError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def version_identifiers(page):
    return [{"Key": item["Key"], "VersionId": item["VersionId"]}
            for kind in ("Versions", "DeleteMarkers")
            for item in page.get(kind, [])]


def delete_batch(bucket, account, objects):
    # A file avoids Windows command-line limits and escaping of arbitrary keys.
    with tempfile.TemporaryDirectory(prefix="lfmesh-s3-delete-") as tmp:
        path = os.path.join(tmp, "delete.json")
        with open(path, "w", encoding="utf-8") as stream:
            json.dump({"Objects": objects, "Quiet": True}, stream)
        response = aws("s3api", "delete-objects", "--bucket", bucket,
                       "--expected-bucket-owner", account, "--delete", "file://" + path)
    if response.get("Errors"):
        raise AwsError("S3 rejected deletions: " + json.dumps(response["Errors"]))


def empty_bucket(bucket, account, timeout):
    deadline = time.monotonic() + timeout
    total = 0
    try:
        aws("s3api", "head-bucket", "--bucket", bucket, "--expected-bucket-owner", account)
    except AwsError as exc:
        if "(404)" in str(exc) or "NoSuchBucket" in str(exc):
            print(f"Already absent: {bucket}", flush=True)
            return
        raise
    # Stop writers before invoking this helper. Do not change versioning here.
    for kind in ("versions", "current"):
        while True:
            if time.monotonic() > deadline:
                raise TimeoutError(f"Timed out emptying {bucket}; check active writers")
            try:
                page = aws("s3api", "list-object-versions" if kind == "versions" else "list-objects-v2",
                           "--bucket", bucket, "--expected-bucket-owner", account,
                           "--max-keys", "1000", "--no-paginate")
                objects = (version_identifiers(page) if kind == "versions" else
                           [{"Key": obj["Key"]} for obj in page.get("Contents", [])])
                if not objects:
                    break
                delete_batch(bucket, account, objects)
            except AwsError as exc:
                # A concurrent Terraform destroy may finish deleting the bucket.
                if "NoSuchBucket" in str(exc):
                    print(f"Deleted by Terraform: {bucket}", flush=True)
                    return
                raise
            total += len(objects)
            print(f"{bucket}: removed {total} objects/versions/markers", flush=True)
    # Verify both views again so new writes fail loudly, rather than reporting success.
    try:
        versions = aws("s3api", "list-object-versions", "--bucket", bucket,
                       "--expected-bucket-owner", account, "--max-keys", "1", "--no-paginate")
        current = aws("s3api", "list-objects-v2", "--bucket", bucket,
                      "--expected-bucket-owner", account, "--max-keys", "1", "--no-paginate")
    except AwsError as exc:
        if "NoSuchBucket" in str(exc):
            return
        raise
    if version_identifiers(versions) or current.get("Contents"):
        raise RuntimeError(f"Bucket {bucket} still has data; stop writers before retrying")
    print(f"Verified empty: {bucket} ({total} deleted)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", default="dev")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--domain", choices=["clientes", "riscos", "transacoes", "contas", "parceiros"])
    group.add_argument("--bucket")
    group.add_argument("--foundation", action="store_true")
    parser.add_argument("--execute", action="store_true", help="Required to delete; otherwise list scope only")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", args.environment):
        parser.error("Invalid environment")
    account = aws("sts", "get-caller-identity")["Account"]
    prefix = f"lfmesh-{args.environment}-"
    allowed = re.compile(re.escape(prefix) +
                         r"(?:(?:clientes|riscos|transacoes|contas|parceiros)-(?:landing|bronze|silver|gold|scripts|plugins)|athena-results)-" +
                         re.escape(account) + r"$")
    if args.bucket:
        buckets = [args.bucket]
    else:
        scope = prefix + ("athena-results-" if args.foundation else args.domain + "-")
        buckets = [b["Name"] for b in aws("s3api", "list-buckets")["Buckets"]
                   if b["Name"].startswith(scope) and allowed.fullmatch(b["Name"])]
    for bucket in buckets:
        if not allowed.fullmatch(bucket):
            parser.error(f"Refusing bucket outside this lab/account: {bucket}")
        print(f"Scope: account={account} bucket={bucket}", flush=True)
        if args.execute:
            empty_bucket(bucket, account, args.timeout)


if __name__ == "__main__":
    main()
