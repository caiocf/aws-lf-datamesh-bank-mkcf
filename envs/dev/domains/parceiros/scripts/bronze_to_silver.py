import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session

source_path = f"s3://{args['source_bucket']}/{args['source_prefix']}/"
target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"

# Lê bronze completo com detecção de partições Hive (pais, dt_ingest como colunas)
df_bronze = spark.read.option("basePath", source_path).parquet(source_path + "*/*/*.parquet")

bronze_count = df_bronze.count()
print(f"Bronze: {bronze_count} registros")

if bronze_count == 0:
    print("Nenhum dado no bronze. Finalizando.")
    sys.exit(0)

df_bronze.printSchema()

# Deduplica por parceiro_id (last dt_ingest wins)
window = Window.partitionBy("parceiro_id").orderBy(F.col("dt_ingest").desc())
df_dedup = (df_bronze.withColumn("rn", F.row_number().over(window))
                     .filter(F.col("rn") == 1)
                     .drop("rn", "dt_ingest"))

print(f"Silver (dedup): {df_dedup.count()} registros")

# Grava particionado por pais (overwrite — idempotente)
df_dedup.write.mode("overwrite").partitionBy("pais").parquet(target_path)

print("Transformação bronze → silver concluída")
