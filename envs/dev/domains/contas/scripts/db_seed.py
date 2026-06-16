import json
import os
import time
import boto3
import pg8000


def get_db_credentials(secret_arn):
    client = boto3.client('secretsmanager')
    response = client.get_secret_value(SecretId=secret_arn)
    return json.loads(response['SecretString'])


def get_sql_from_s3(bucket, key):
    s3 = boto3.client('s3')
    response = s3.get_object(Bucket=bucket, Key=key)
    return response['Body'].read().decode('utf-8')


def run_seed(db_host, db_port, db_name, user, password, sql_bucket, create_key, seed_key):
    create_sql = get_sql_from_s3(sql_bucket, create_key)
    seed_sql = get_sql_from_s3(sql_bucket, seed_key)

    conn = pg8000.connect(
        host=db_host,
        port=db_port,
        database=db_name,
        user=user,
        password=password
    )
    conn.autocommit = True
    cursor = conn.cursor()

    cursor.execute(create_sql)
    print("CREATE TABLE executado")

    cursor.execute(seed_sql)
    print("SEED INSERTs executado")

    cursor.execute("SELECT count(*) FROM contas")
    count = cursor.fetchone()[0]

    cursor.close()
    conn.close()

    return count


def start_workflow(workflow_name, delay_seconds=0):
    if delay_seconds > 0:
        print(f"Aguardando {delay_seconds}s para o DMS concluir a escrita no S3 antes de iniciar o workflow")
        time.sleep(delay_seconds)

    glue = boto3.client('glue')
    run = glue.start_workflow_run(Name=workflow_name)
    print(f"Workflow {workflow_name} iniciado: {run['RunId']}")
    return run['RunId']


def handler(event, context):
    action = event.get('action', 'seed')
    workflow_delay = int(os.environ.get('WORKFLOW_START_DELAY_SECONDS', '45'))

    if action == 'seed':
        secret_arn = os.environ['DB_SECRET_ARN']
        db_host = os.environ['DB_HOST']
        db_port = int(os.environ.get('DB_PORT', '5432'))
        db_name = os.environ['DB_NAME']
        sql_bucket = os.environ['SQL_BUCKET']
        create_table_key = os.environ['SQL_CREATE_TABLE_KEY']
        seed_inserts_key = os.environ['SQL_SEED_INSERTS_KEY']

        creds = get_db_credentials(secret_arn)
        count = run_seed(
            db_host, db_port, db_name,
            creds['username'], creds['password'],
            sql_bucket, create_table_key, seed_inserts_key
        )
        msg = f"Seed concluido: {count} registros na tabela contas"
        print(msg)
        return {"statusCode": 200, "body": msg}

    elif action == 'start_workflow':
        workflow_name = os.environ['WORKFLOW_NAME']
        run_id = start_workflow(workflow_name, workflow_delay)
        return {"statusCode": 200, "body": f"Workflow iniciado: {run_id}"}

    elif action == 'seed_and_workflow':
        # Faz seed + dispara workflow (usado no terraform apply)
        secret_arn = os.environ['DB_SECRET_ARN']
        db_host = os.environ['DB_HOST']
        db_port = int(os.environ.get('DB_PORT', '5432'))
        db_name = os.environ['DB_NAME']
        sql_bucket = os.environ['SQL_BUCKET']
        create_table_key = os.environ['SQL_CREATE_TABLE_KEY']
        seed_inserts_key = os.environ['SQL_SEED_INSERTS_KEY']
        workflow_name = os.environ['WORKFLOW_NAME']

        creds = get_db_credentials(secret_arn)
        count = run_seed(
            db_host, db_port, db_name,
            creds['username'], creds['password'],
            sql_bucket, create_table_key, seed_inserts_key
        )
        run_id = start_workflow(workflow_name, workflow_delay)
        msg = f"Seed: {count} registros. Workflow iniciado: {run_id}"
        print(msg)
        return {"statusCode": 200, "body": msg}

    else:
        return {"statusCode": 400, "body": f"Acao invalida: {action}"}
