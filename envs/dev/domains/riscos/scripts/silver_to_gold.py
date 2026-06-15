import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session

source_path = f"s3://{args['source_bucket']}/{args['source_prefix']}/"
target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"

# Lê silver (particionado por pais)
df = spark.read.option("basePath", source_path).parquet(source_path)
print(f"Silver: {df.count()} registros")

# Gold = alertas nao fechados (aberto + em_analise) para analytics de fraude
df_gold = df.filter(F.col("status") != "fechado")
print(f"Gold: {df_gold.count()} alertas ativos (aberto + em_analise)")

# Grava particionado por pais (overwrite)
df_gold.write.mode("overwrite").partitionBy("pais").parquet(target_path)
print("Transformacao silver -> gold concluida")
