import json
import os

import boto3

ACTIVE_STATES = {"RUNNING", "STOPPING"}


def get_active_workflow_run(glue_client, workflow_name):
    runs = glue_client.get_workflow_runs(
        Name=workflow_name,
        IncludeGraph=False,
        MaxResults=5,
    ).get("Runs", [])

    for run in runs:
        status = run.get("Status", "")
        if status in ACTIVE_STATES:
            return run.get("WorkflowRunId"), status

    return None, None


def handler(event, context):
    s3 = boto3.client("s3")
    glue = boto3.client("glue")

    landing_bucket = os.environ["LANDING_BUCKET"]
    source_key = os.environ["SOURCE_KEY"]
    workflow_name = os.environ["GLUE_WORKFLOW_NAME"]

    s3.head_object(Bucket=landing_bucket, Key=source_key)
    print(f"CSV encontrado em s3://{landing_bucket}/{source_key}")

    active_run_id, active_status = get_active_workflow_run(glue, workflow_name)
    if active_run_id:
        message = (
            f"Workflow {workflow_name} ja possui run ativo "
            f"{active_run_id} com status {active_status}"
        )
        print(message)
        return {
            "statusCode": 200,
            "body": json.dumps({
                "source": f"s3://{landing_bucket}/{source_key}",
                "workflow_name": workflow_name,
                "workflow_run": active_run_id,
                "workflow_status": active_status,
                "started_new_run": False,
            }),
        }

    run = glue.start_workflow_run(Name=workflow_name)
    print(f"Workflow {workflow_name} disparado: {run['RunId']}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "source": f"s3://{landing_bucket}/{source_key}",
            "workflow_name": workflow_name,
            "workflow_run": run["RunId"],
            "started_new_run": True,
        }),
    }
