import sys
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import BytesIO
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

s3 = boto3.client('s3')

# Lista todos os Parquets no bronze (todas as partições)
paginator = s3.get_paginator('list_objects_v2')
pages = paginator.paginate(Bucket=args['source_bucket'], Prefix=args['source_prefix'])

frames = []
for page in pages:
    for obj in page.get('Contents', []):
        key = obj['Key']
        if not key.endswith('.parquet'):
            continue

        # Extrai pais e dt_ingest do path Hive-style
        parts = key.split('/')
        pais_val = None
        dt_val = None
        for part in parts:
            if part.startswith('pais='):
                pais_val = part.split('=')[1]
            elif part.startswith('dt_ingest='):
                dt_val = part.split('=')[1]

        # Lê Parquet
        response = s3.get_object(Bucket=args['source_bucket'], Key=key)
        df = pd.read_parquet(BytesIO(response['Body'].read()))
        df['pais'] = pais_val
        df['dt_ingest'] = dt_val
        frames.append(df)

if not frames:
    print("Nenhum dado encontrado no bronze")
    sys.exit(0)

# Concatena tudo
df_all = pd.concat(frames, ignore_index=True)
print(f"Bronze: {len(df_all)} registros lidos")

# Deduplica: última dt_ingest vence por cliente_id
df_dedup = (
    df_all.sort_values('dt_ingest', ascending=False)
          .drop_duplicates(subset=['cliente_id'], keep='first')
          .drop(columns=['dt_ingest'])
)
print(f"Silver: {len(df_dedup)} registros após deduplicação")

# Grava particionado por pais no silver
for pais_val, pais_df in df_dedup.groupby('pais'):
    data_df = pais_df.drop(columns=['pais'])

    table = pa.Table.from_pandas(data_df, preserve_index=False)
    buffer = BytesIO()
    pq.write_table(table, buffer)

    target_key = f"{args['target_prefix']}/pais={pais_val}/data.parquet"
    s3.put_object(
        Bucket=args['target_bucket'],
        Key=target_key,
        Body=buffer.getvalue(),
        ContentType='application/octet-stream'
    )
    print(f"Silver partição pais={pais_val}: {len(data_df)} registros")

print("Transformação bronze → silver concluída")
