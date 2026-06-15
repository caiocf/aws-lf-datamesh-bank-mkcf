import json
import os
import random
import uuid
from datetime import datetime, timezone

import boto3
from kafka import KafkaAdminClient, KafkaProducer
from kafka.admin import NewTopic
from aws_msk_iam_sasl_signer.MSKAuthTokenProvider import generate_auth_token
from kafka.errors import TopicAlreadyExistsError


class MSKTokenProvider:
    def token(self):
        region = os.environ.get("AWS_REGION", "us-east-1")
        token, _ = generate_auth_token(region)
        return token


producer_instance = None
topic_ready = False


def build_kafka_config():
    bootstrap_servers = [
        b.strip() for b in os.environ["MSK_BOOTSTRAP_SERVERS"].split(",")
    ]

    return {
        "bootstrap_servers": bootstrap_servers,
        "security_protocol": "SASL_SSL",
        "sasl_mechanism": "OAUTHBEARER",
        "sasl_oauth_token_provider": MSKTokenProvider(),
        "request_timeout_ms": 15000,
    }


def ensure_topic_exists(topic_name):
    global topic_ready
    if topic_ready:
        return

    admin_client = KafkaAdminClient(
        client_id="lambda-riscos-admin",
        **build_kafka_config(),
    )

    try:
        existing_topics = set(admin_client.list_topics())
        if topic_name not in existing_topics:
            admin_client.create_topics([
                NewTopic(name=topic_name, num_partitions=2, replication_factor=3)
            ])
            print(f"Topico {topic_name} criado")
        else:
            print(f"Topico {topic_name} ja existe")
    except TopicAlreadyExistsError:
        print(f"Topico {topic_name} ja existe")
    finally:
        admin_client.close()

    topic_ready = True


def get_producer():
    global producer_instance
    if producer_instance is not None:
        return producer_instance

    producer_instance = KafkaProducer(
        client_id="lambda-riscos-producer",
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
        retries=3,
        **build_kafka_config(),
    )
    return producer_instance


def generate_alerts(num_alerts):
    clientes = ['c001', 'c002', 'c003', 'c004', 'c005', 'c006', 'c007', 'c008']
    contas = {
        'c001': 'a001', 'c002': 'a002', 'c003': 'a003', 'c004': 'a004',
        'c005': 'a006', 'c006': 'a007', 'c007': 'a008', 'c008': 'a009'
    }
    paises = {
        'c001': 'BR', 'c002': 'BR', 'c003': 'US', 'c004': 'BR',
        'c005': 'US', 'c006': 'AR', 'c007': 'AR', 'c008': 'DE'
    }
    severidades = ['critica', 'alta', 'media', 'baixa']
    pesos_severidade = [0.1, 0.3, 0.4, 0.2]
    motivos = [
        'transacao_incomum', 'login_suspeito', 'limite_transacional',
        'pais_bloqueado', 'horario_atipico', 'multiplas_tentativas',
        'device_novo', 'valor_elevado'
    ]
    statuses = ['aberto', 'em_analise', 'fechado']
    pesos_status = [0.5, 0.3, 0.2]

    now = datetime.now(timezone.utc)
    alerts = []

    for _ in range(num_alerts):
        cliente = random.choice(clientes)
        alerts.append({
            'alerta_id': f"al-{uuid.uuid4().hex[:8]}",
            'cliente_id': cliente,
            'conta_id': contas[cliente],
            'severidade': random.choices(severidades, weights=pesos_severidade, k=1)[0],
            'status': random.choices(statuses, weights=pesos_status, k=1)[0],
            'pais': paises[cliente],
            'motivo': random.choice(motivos),
            'score_risco': round(random.uniform(0.1, 1.0), 3),
            'data_alerta': now.isoformat()
        })

    return alerts


def handler(event, context):
    topic = os.environ["TOPIC_NAME"]
    num_alerts = int(os.environ.get("NUM_ALERTS", "50"))

    ensure_topic_exists(topic)
    kafka_producer = get_producer()
    alerts = generate_alerts(num_alerts)

    for alert in alerts:
        future = kafka_producer.send(topic, key=alert['alerta_id'], value=alert)
        future.get(timeout=10)

    kafka_producer.flush()

    msg = f"Publicados {num_alerts} alertas no topico {topic}"
    print(msg)

    return {"statusCode": 200, "body": msg}
