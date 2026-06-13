import json


def handler(event, context):
    parceiros = [
        {"parceiro_id": "p001", "nome_parceiro": "Parceiro Pagamentos", "categoria": "pagamentos", "pais": "BR", "contrato_status": "ativo"},
        {"parceiro_id": "p002", "nome_parceiro": "Parceiro Antifraude", "categoria": "risco", "pais": "BR", "contrato_status": "ativo"},
        {"parceiro_id": "p003", "nome_parceiro": "Parceiro Global", "categoria": "dados", "pais": "US", "contrato_status": "ativo"},
        {"parceiro_id": "p004", "nome_parceiro": "Parceiro Analytics", "categoria": "analytics", "pais": "BR", "contrato_status": "inativo"},
        {"parceiro_id": "p005", "nome_parceiro": "Parceiro Cloud EU", "categoria": "infraestrutura", "pais": "DE", "contrato_status": "ativo"},
        {"parceiro_id": "p006", "nome_parceiro": "Parceiro Credito", "categoria": "credito", "pais": "BR", "contrato_status": "ativo"},
        {"parceiro_id": "p007", "nome_parceiro": "Parceiro Seguros", "categoria": "seguros", "pais": "AR", "contrato_status": "ativo"},
        {"parceiro_id": "p008", "nome_parceiro": "Parceiro KYC", "categoria": "compliance", "pais": "US", "contrato_status": "ativo"},
        {"parceiro_id": "p009", "nome_parceiro": "Parceiro Open Banking", "categoria": "open_banking", "pais": "BR", "contrato_status": "ativo"},
        {"parceiro_id": "p010", "nome_parceiro": "Parceiro Latam", "categoria": "pagamentos", "pais": "AR", "contrato_status": "inativo"},
    ]
    return {
        "statusCode": 200,
        "body": json.dumps({"parceiros": parceiros})
    }
