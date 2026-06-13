import sys
import boto3
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from io import StringIO, BytesIO
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(sys.argv, ['source_bucket', 'source_key', 'target_bucket', 'target_prefix'])

s3 = boto3.client('s3')

# Lê CSV do landing zone
response = s3.get_object(Bucket=args['source_bucket'], Key=args['source_key'])
csv_content = response['Body'].read().decode('utf-8')

# Converte para DataFrame (todas colunas como string para compatibilidade com Glue)
df = pd.read_csv(StringIO(csv_content), dtype=str)

# Particiona por pais e dt_ingest, grava cada partição como Parquet
partition_cols = ['pais', 'dt_ingest']
for keys, partition_df in df.groupby(partition_cols):
    pais_val, dt_val = keys
    data_df = partition_df.drop(columns=partition_cols)

    table = pa.Table.from_pandas(data_df, preserve_index=False)
    buffer = BytesIO()
    pq.write_table(table, buffer)

    target_key = f"{args['target_prefix']}/pais={pais_val}/dt_ingest={dt_val}/data.parquet"
    s3.put_object(
        Bucket=args['target_bucket'],
        Key=target_key,
        Body=buffer.getvalue(),
        ContentType='application/octet-stream'
    )
    print(f"Partição pais={pais_val}/dt_ingest={dt_val}: {len(data_df)} registros")

print(f"Total: {len(df)} registros convertidos para Parquet particionado")
