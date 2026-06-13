import json
import boto3
import urllib.request
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO
from datetime import date
import os


def handler(event, context):
    api_url = os.environ['API_URL']
    target_bucket = os.environ['TARGET_BUCKET']
    target_prefix = os.environ['TARGET_PREFIX']
    workflow_name = os.environ['WORKFLOW_NAME']

    # 1. Chama API mock
    req = urllib.request.Request(api_url)
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode())

    parceiros = data['parceiros']
    print(f"API retornou {len(parceiros)} parceiros")

    dt_ingest = date.today().isoformat()

    # 2. Agrupa por pais e grava Parquet particionado
    by_pais = {}
    for p in parceiros:
        pais = p.pop('pais')
        by_pais.setdefault(pais, []).append(p)

    s3 = boto3.client('s3')
    for pais_val, records in by_pais.items():
        schema = pa.schema([
            ('parceiro_id', pa.string()),
            ('nome_parceiro', pa.string()),
            ('categoria', pa.string()),
            ('contrato_status', pa.string()),
        ])
        table = pa.table({
            'parceiro_id': [r['parceiro_id'] for r in records],
            'nome_parceiro': [r['nome_parceiro'] for r in records],
            'categoria': [r['categoria'] for r in records],
            'contrato_status': [r['contrato_status'] for r in records],
        }, schema=schema)

        buffer = BytesIO()
        pq.write_table(table, buffer)

        key = f"{target_prefix}/pais={pais_val}/dt_ingest={dt_ingest}/data.parquet"
        s3.put_object(Bucket=target_bucket, Key=key, Body=buffer.getvalue())
        print(f"Gravado pais={pais_val}/dt_ingest={dt_ingest}: {len(records)} registros")

    # 3. Dispara Glue Workflow
    glue = boto3.client('glue')
    run = glue.start_workflow_run(Name=workflow_name)
    print(f"Workflow {workflow_name} disparado: {run['RunId']}")

    return {"statusCode": 200, "body": json.dumps({"parceiros_ingeridos": len(parceiros), "workflow_run": run['RunId']})}
