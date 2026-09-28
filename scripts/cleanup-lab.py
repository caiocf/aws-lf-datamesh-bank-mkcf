"""Ordered lab teardown. Requires Terraform, AWS CLI and Python 3.9+."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import time

spec = importlib.util.spec_from_file_location("empty_lab", Path(__file__).with_name("empty-lab-buckets.py"))
s3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s3)
aws = s3.aws
DOMAINS = ("clientes", "riscos", "transacoes", "contas", "parceiros")
ACTIVE = {"STARTING", "RUNNING", "STOPPING", "WAITING"}


def wait_for(label, pending, timeout=900):
    deadline = time.monotonic() + timeout
    while pending():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Timed out waiting for {label}; teardown stopped safely")
        print(f"Waiting for {label}...", flush=True)
        time.sleep(15)


def quiesce(prefix, region):
    def call(*args):
        return aws(*args, "--region", region)

    for rule in call("events", "list-rules", "--name-prefix", prefix).get("Rules", []):
        if rule["State"] != "DISABLED":
            call("events", "disable-rule", "--name", rule["Name"])
            print("Disabled rule: " + rule["Name"], flush=True)

    for trigger in call("glue", "get-triggers").get("Triggers", []):
        if trigger["Name"].startswith(prefix) and trigger["State"] in {"ACTIVATED", "ACTIVATING"}:
            call("glue", "stop-trigger", "--name", trigger["Name"])

    # Disable schedules before stopping jobs so watchdogs cannot restart them.
    jobs = [name for name in call("glue", "list-jobs").get("JobNames", []) if name.startswith(prefix)]
    def active_runs(job):
        return [run["Id"] for run in call("glue", "get-job-runs", "--job-name", job).get("JobRuns", [])
                if run["JobRunState"] in ACTIVE]
    for job in jobs:
        ids = active_runs(job)
        for start in range(0, len(ids), 25):
            response = call("glue", "batch-stop-job-run", "--job-name", job,
                            "--job-run-ids", *ids[start:start + 25])
            if response.get("Errors"):
                raise RuntimeError(f"Cannot stop {job}: {response['Errors']}")
        if ids:
            wait_for(job, lambda: active_runs(job))

    for task in call("dms", "describe-replication-tasks").get("ReplicationTasks", []):
        if not task["ReplicationTaskIdentifier"].startswith(prefix):
            continue
        arn = task["ReplicationTaskArn"]
        status = task["Status"]
        if status in {"running", "starting", "stopping"}:
            if status != "stopping":
                call("dms", "stop-replication-task", "--replication-task-arn", arn)
            def dms_pending():
                tasks = call("dms", "describe-replication-tasks", "--filters",
                             "Name=replication-task-arn,Values=" + arn).get("ReplicationTasks", [])
                return any(t["Status"] not in {"stopped", "failed", "ready"} for t in tasks)
            wait_for(task["ReplicationTaskIdentifier"], dms_pending)

    # MSK Connect is an independent S3 writer. Delete before purging its bucket.
    for connector in call("kafkaconnect", "list-connectors", "--connector-name-prefix", prefix).get("connectors", []):
        arn = connector["connectorArn"]
        if connector["connectorState"] != "DELETING":
            call("kafkaconnect", "delete-connector", "--connector-arn", arn)
        def connector_pending():
            try:
                call("kafkaconnect", "describe-connector", "--connector-arn", arn)
                return True
            except s3.AwsError as exc:
                if "NotFoundException" in str(exc):
                    return False
                raise
        wait_for(connector["connectorName"], connector_pending)


def state_directories(root, environment, domain=None):
    base = (root / "envs" / environment).resolve()
    if root not in base.parents:
        raise ValueError("Environment escaped workspace")
    if domain:
        return [base / "domains" / domain]
    return ([base / "observability"] + [base / "domains" / d for d in DOMAINS]
            + [base / name for name in ("foundation", "consumer-roles", "network")])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", default=os.environ.get("ENV", "dev"))
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    parser.add_argument("--domain", choices=DOMAINS)
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", args.environment):
        parser.error("Invalid environment")
    root = Path(__file__).resolve().parent.parent
    paths = state_directories(root, args.environment, args.domain)
    for path in paths:
        if (path / ".terraform.tfstate.lock.info").exists():
            raise RuntimeError(f"Terraform lock exists in {path}; do not run concurrent destroy")
    account = aws("sts", "get-caller-identity")["Account"]
    print(f"DESTROY lab lfmesh-{args.environment}, account {account}, region {args.region}", flush=True)
    if not args.yes and input("Type DESTRUIR to confirm: ").strip() != "DESTRUIR":
        return
    prefix = f"lfmesh-{args.environment}-" + (args.domain + "-" if args.domain else "")
    quiesce(prefix, args.region)
    # Scope S3 deletion to exact lab names and the authenticated account.
    allowed = re.compile(re.escape(f"lfmesh-{args.environment}-") +
                         r"(?:(?:clientes|riscos|transacoes|contas|parceiros)-(?:landing|bronze|silver|gold|scripts|plugins)|athena-results)-" +
                         re.escape(account) + r"$")
    buckets = [b["Name"] for b in aws("s3api", "list-buckets")["Buckets"]
               if b["Name"].startswith(prefix) and allowed.fullmatch(b["Name"])]
    for bucket in buckets:
        s3.empty_bucket(bucket, account, timeout=900)
    for path in paths:
        if not (path / "terraform.tfstate").exists():
            print(f"No local state: {path}; skipped", flush=True)
            continue
        if (path / ".terraform.tfstate.lock.info").exists():
            raise RuntimeError(f"Terraform lock appeared in {path}")
        print(f"Destroying {path.relative_to(root)}", flush=True)
        # Terraform alone deletes managed infrastructure and updates its state.
        subprocess.run(["terraform", f"-chdir={path}", "destroy", "-auto-approve",
                        "-input=false", "-no-color", "-lock-timeout=30s"], check=True)
    remaining = [b["Name"] for b in aws("s3api", "list-buckets")["Buckets"]
                 if b["Name"].startswith(prefix) and allowed.fullmatch(b["Name"])]
    if remaining:
        raise RuntimeError(f"Lab buckets still exist: {remaining}")
    print("Lab teardown completed; no scoped S3 buckets remain.", flush=True)


if __name__ == "__main__":
    main()
