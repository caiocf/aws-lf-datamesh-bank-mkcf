import sys
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

s3 = boto3.client('s3')

# Lista todos os Parquets no silver
paginator = s3.get_paginator('list_objects_v2')
pages = paginator.paginate(Bucket=args['source_bucket'], Prefix=args['source_prefix'])

frames = []
for page in pages:
    for obj in page.get('Contents', []):
        key = obj['Key']
        if not key.endswith('.parquet'):
            continue

        # Extrai pais do path
        parts = key.split('/')
        pais_val = None
        for part in parts:
            if part.startswith('pais='):
                pais_val = part.split('=')[1]

        response = s3.get_object(Bucket=args['source_bucket'], Key=key)
        df = pd.read_parquet(BytesIO(response['Body'].read()))
        df['pais'] = pais_val
        frames.append(df)

if not frames:
    print("Nenhum dado encontrado no silver")
    sys.exit(0)

df_all = pd.concat(frames, ignore_index=True)
print(f"Silver: {len(df_all)} registros lidos")

# Enriquecimento: adiciona colunas de outros domínios (NULL por agora)
# Futuro: joins com dev_silver_contas, dev_silver_transacoes, dev_gold_alertas
df_all['total_contas'] = None
df_all['volume_transacoes'] = None
df_all['ultima_transacao'] = None
df_all['score_risco'] = None

print(f"Gold: {len(df_all)} registros enriquecidos (colunas extras: NULL até domínios disponíveis)")

# Grava particionado por pais no gold
for pais_val, pais_df in df_all.groupby('pais'):
    data_df = pais_df.drop(columns=['pais'])

    # Define schema explícito para manter tipos corretos
    schema = pa.schema([
        ('cliente_id', pa.string()),
        ('nome', pa.string()),
        ('cpf', pa.string()),
        ('email', pa.string()),
        ('segmento', pa.string()),
        ('total_contas', pa.int32()),
        ('volume_transacoes', pa.float64()),
        ('ultima_transacao', pa.string()),
        ('score_risco', pa.string()),
    ])

    table = pa.Table.from_pandas(data_df, schema=schema, preserve_index=False)
    buffer = BytesIO()
    pq.write_table(table, buffer)

    target_key = f"{args['target_prefix']}/pais={pais_val}/data.parquet"
    s3.put_object(
        Bucket=args['target_bucket'],
        Key=target_key,
        Body=buffer.getvalue(),
        ContentType='application/octet-stream'
    )
    print(f"Gold partição pais={pais_val}: {len(data_df)} registros")

print("Transformação silver → gold concluída")
