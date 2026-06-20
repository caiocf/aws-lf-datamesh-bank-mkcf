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

# Lê silver clientes (particionado por pais)
df = spark.read.option("basePath", source_path).parquet(source_path)
print(f"Silver clientes: {df.count()} registros")

# --- Enriquecimento cross-dominio via leitura direta S3 ---
# Partition projection e feature do Athena, nao do Spark.
# Lemos diretamente o path S3 registrado no Lake Formation.

account_id = spark.conf.get("spark.hadoop.fs.s3.awsAccountId", "")
if not account_id:
    import boto3
    account_id = boto3.client("sts").get_caller_identity()["Account"]

prefix = f"lfmesh-dev"

# Contas: total de contas ativas por cliente
try:
    contas_path = f"s3://{prefix}-contas-gold-{account_id}/contas_ativas/"
    df_contas = spark.read.parquet(contas_path)

    df_contas_agg = (
        df_contas.groupBy("cliente_id")
        .agg(F.count("conta_id").alias("total_contas"))
    )
    print(f"Contas ativas: {df_contas_agg.count()} clientes com contas")
except Exception as e:
    print(f"Aviso: nao foi possivel ler contas_ativas - {e}")
    df_contas_agg = None

# Transacoes: volume total e ultima transacao por cliente
try:
    txn_path = f"s3://{prefix}-transacoes-gold-{account_id}/transacoes_curated/"
    df_txn = spark.read.parquet(txn_path)

    df_txn_agg = (
        df_txn.groupBy("cliente_id")
        .agg(
            F.sum("valor").alias("volume_transacoes"),
            F.max("data_transacao").alias("ultima_transacao")
        )
    )
    print(f"Transacoes curated: {df_txn_agg.count()} clientes com transacoes")
except Exception as e:
    print(f"Aviso: nao foi possivel ler transacoes_curated - {e}")
    df_txn_agg = None

# Riscos: max score_risco por cliente (pior caso)
try:
    riscos_path = f"s3://{prefix}-riscos-gold-{account_id}/alertas_fraude/"
    df_riscos = spark.read.parquet(riscos_path)

    df_riscos_agg = (
        df_riscos.groupBy("cliente_id")
        .agg(F.max("score_risco").alias("score_risco_raw"))
        .withColumn("score_risco", F.col("score_risco_raw").cast("string"))
        .drop("score_risco_raw")
    )
    print(f"Alertas fraude: {df_riscos_agg.count()} clientes com score de risco")
except Exception as e:
    print(f"Aviso: nao foi possivel ler alertas_fraude - {e}")
    df_riscos_agg = None

# Left join: clientes <- contas <- transacoes <- riscos
if df_contas_agg is not None:
    df = df.join(df_contas_agg, on="cliente_id", how="left")
else:
    df = df.withColumn("total_contas", F.lit(None).cast("int"))

if df_txn_agg is not None:
    df = df.join(df_txn_agg, on="cliente_id", how="left")
else:
    df = df.withColumn("volume_transacoes", F.lit(None).cast("double"))
    df = df.withColumn("ultima_transacao", F.lit(None).cast("string"))

if df_riscos_agg is not None:
    df = df.join(df_riscos_agg, on="cliente_id", how="left")
else:
    df = df.withColumn("score_risco", F.lit(None).cast("string"))

# --- Mascaramento PII: hash com salt + partial mask + drop originais ---
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
    F.col("total_contas").cast("int"),
    F.col("volume_transacoes").cast("double"),
    "ultima_transacao", "score_risco",
    "pais"
)

print(f"Gold: {df_gold.count()} registros enriquecidos e mascarados")

# Grava particionado por pais (overwrite)
df_gold.write.mode("overwrite").partitionBy("pais").parquet(target_path)
print("Transformacao silver -> gold concluida (360 real + PII mascarada)")

job.commit()
