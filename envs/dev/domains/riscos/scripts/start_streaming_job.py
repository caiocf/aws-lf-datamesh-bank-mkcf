import json
import os

import boto3


ACTIVE_STATES = {"STARTING", "RUNNING", "STOPPING", "WAITING"}


def handler(event, context):
    job_name = os.environ["JOB_NAME"]
    glue = boto3.client("glue")

    runs = glue.get_job_runs(JobName=job_name, MaxResults=5).get("JobRuns", [])
    for run in runs:
        state = run.get("JobRunState", "")
        if state in ACTIVE_STATES:
            message = f"Glue job {job_name} already active in state {state}"
            print(message)
            return {"statusCode": 200, "body": json.dumps({"message": message})}

    response = glue.start_job_run(JobName=job_name)
    run_id = response["JobRunId"]
    message = f"Glue job {job_name} started with run id {run_id}"
    print(message)

    return {
        "statusCode": 200,
        "body": json.dumps({"message": message, "job_run_id": run_id}),
    }
