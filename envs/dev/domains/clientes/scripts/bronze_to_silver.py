import sys
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

SALT = "lfmesh-clientes-2026"

source_path = f"s3://{args['source_bucket']}/{args['source_prefix']}/"
target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"

# Lê todos os Parquets do bronze (particionado por pais/dt_ingest)
df = spark.read.option("basePath", source_path).parquet(source_path)
total = df.count()
print(f"Bronze: {total} registros")

if total == 0:
    print("Nenhum dado no bronze. Finalizando.")
else:
    # Deduplica: última dt_ingest vence por cliente_id
    from pyspark.sql.window import Window
    window = Window.partitionBy("cliente_id").orderBy(F.col("dt_ingest").desc())
    df_dedup = (
        df.withColumn("rn", F.row_number().over(window))
          .filter(F.col("rn") == 1)
          .drop("rn", "dt_ingest")
    )

    # Mascaramento: gera hashes irreversíveis com salt para joins técnicos
    df_silver = (
        df_dedup
        .withColumn("cpf_hash", F.sha2(F.concat(F.col("cpf"), F.lit(SALT)), 256))
        .withColumn("email_hash", F.sha2(F.concat(F.col("email"), F.lit(SALT)), 256))
    )

    print(f"Silver: {df_silver.count()} registros após deduplicação (com cpf_hash, email_hash)")

    # Grava particionado por pais (overwrite)
    df_silver.write.mode("overwrite").partitionBy("pais").parquet(target_path)
    print("Transformação bronze → silver concluída")

job.commit()
