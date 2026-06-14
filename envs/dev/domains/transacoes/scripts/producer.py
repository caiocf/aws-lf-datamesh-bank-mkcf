import json
import os
import socket
import random
import uuid
from datetime import datetime, timezone

import boto3
from kafka import KafkaProducer


class MSKTokenProvider:
    """Token provider para IAM auth (fallback)."""
    def token(self):
        from aws_msk_iam_sasl_signer import MSKAuthTokenProvider
        region = os.environ.get("MSK_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
        token, _ = MSKAuthTokenProvider.generate_auth_token(region)
        return token


def get_scram_credentials(secret_arn):
    """Recupera username/password do Secrets Manager."""
    client = boto3.client('secretsmanager')
    response = client.get_secret_value(SecretId=secret_arn)
    return json.loads(response['SecretString'])


# Reutiliza producer entre invocacoes (Lambda warm start)
producer = None


def get_producer():
    global producer

    if producer is not None:
        return producer

    bootstrap_servers = [
        broker.strip()
        for broker in os.environ["MSK_BOOTSTRAP_SERVERS"].split(",")
    ]
    auth_method = os.environ.get("AUTH_METHOD", "SCRAM")

    common_config = {
        'bootstrap_servers': bootstrap_servers,
        'client_id': f"lambda-{socket.gethostname()}",
        'value_serializer': lambda v: json.dumps(v).encode("utf-8"),
        'key_serializer': lambda k: k.encode("utf-8") if k else None,
        'retries': 3,
        'request_timeout_ms': 15000,
    }

    if auth_method == 'SCRAM':
        creds = get_scram_credentials(os.environ["MSK_SECRET_ARN"])
        common_config.update({
            'security_protocol': 'SASL_SSL',
            'sasl_mechanism': 'SCRAM-SHA-512',
            'sasl_plain_username': creds['username'],
            'sasl_plain_password': creds['password'],
        })

    elif auth_method == 'IAM':
        common_config.update({
            'security_protocol': 'SASL_SSL',
            'sasl_mechanism': 'OAUTHBEARER',
            'sasl_oauth_token_provider': MSKTokenProvider(),
        })

    elif auth_method == 'PLAINTEXT':
        common_config.update({
            'security_protocol': 'PLAINTEXT',
        })

    else:
        raise ValueError(f"AUTH_METHOD '{auth_method}' nao suportado. Use: SCRAM, IAM, PLAINTEXT")

    producer = KafkaProducer(**common_config)
    return producer


def generate_transactions(num_transactions):
    contas = ['a001', 'a002', 'a003', 'a004', 'a006', 'a007', 'a008', 'a009', 'a010']
    clientes = {
        'a001': 'c001', 'a002': 'c002', 'a003': 'c003', 'a004': 'c004',
        'a006': 'c006', 'a007': 'c007', 'a008': 'c008', 'a009': 'c009', 'a010': 'c010'
    }
    paises = {
        'a001': 'BR', 'a002': 'BR', 'a003': 'US', 'a004': 'BR',
        'a006': 'US', 'a007': 'AR', 'a008': 'AR', 'a009': 'DE', 'a010': 'DE'
    }
    categorias = ['mercado', 'transferencia', 'servicos', 'lazer', 'saude', 'educacao', 'transporte']
    moedas = {'BR': 'BRL', 'US': 'USD', 'AR': 'ARS', 'DE': 'EUR'}

    now = datetime.now(timezone.utc)
    transactions = []

    for _ in range(num_transactions):
        conta = random.choice(contas)
        pais = paises[conta]
        transactions.append({
            'transacao_id': str(uuid.uuid4())[:8],
            'conta_id': conta,
            'cliente_id': clientes[conta],
            'valor': round(random.uniform(10.0, 5000.0), 2),
            'moeda': moedas[pais],
            'categoria': random.choice(categorias),
            'pais': pais,
            'data_transacao': now.isoformat()
        })

    return transactions


def handler(event, context):
    import time

    topic = os.environ["TOPIC_NAME"]
    num_transactions = int(os.environ.get("NUM_TRANSACTIONS", "100"))
    workflow_name = os.environ.get("GLUE_WORKFLOW_NAME", "")

    kafka_producer = get_producer()
    transactions = generate_transactions(num_transactions)

    for txn in transactions:
        future = kafka_producer.send(topic, key=txn['transacao_id'], value=txn)
        future.get(timeout=10)

    kafka_producer.flush()

    msg = f"Publicadas {num_transactions} transacoes no topico {topic}"
    print(msg)

    if workflow_name:
        time.sleep(10)
        glue = boto3.client('glue')
        glue.start_workflow_run(Name=workflow_name)
        print(f"Workflow {workflow_name} disparado")
        msg += f" | Workflow {workflow_name} disparado"

    return {"statusCode": 200, "body": msg}
