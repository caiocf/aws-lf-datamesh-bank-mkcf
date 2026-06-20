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

# Lê silver (particionado por pais)
df = spark.read.option("basePath", source_path).parquet(source_path)
print(f"Silver: {df.count()} registros")

# Enriquecimento: colunas de outros domínios (NULL por agora)
df = (
    df.withColumn("total_contas", F.lit(None).cast("int"))
      .withColumn("volume_transacoes", F.lit(None).cast("double"))
      .withColumn("ultima_transacao", F.lit(None).cast("string"))
      .withColumn("score_risco", F.lit(None).cast("string"))
)

# Mascaramento PII: hash com salt + partial mask + drop originais
df_gold = (
    df.withColumn("cpf_hash", F.sha2(F.concat(F.col("cpf"), F.lit(SALT)), 256))
      .withColumn("email_hash", F.sha2(F.concat(F.col("email"), F.lit(SALT)), 256))
      .withColumn("cpf_masked", F.regexp_replace(F.col("cpf"), r"(\d{3})(\d{3})(\d{3})(\d{2})", r"***.***.***-$4"))
      .withColumn("email_masked", F.regexp_replace(F.col("email"), r"(^.).*(@.*$)", r"$1***$2"))
      .drop("cpf", "email")
)

# Reordena colunas para schema do Glue Catalog
df_gold = df_gold.select(
    "cliente_id", "nome", "cpf_masked", "cpf_hash",
    "email_masked", "email_hash", "segmento",
    "total_contas", "volume_transacoes", "ultima_transacao", "score_risco",
    "pais"
)

print(f"Gold: {df_gold.count()} registros mascarados")

# Grava particionado por pais (overwrite)
df_gold.write.mode("overwrite").partitionBy("pais").parquet(target_path)
print("Transformação silver → gold concluída (PII mascarada com salt)")

job.commit()
