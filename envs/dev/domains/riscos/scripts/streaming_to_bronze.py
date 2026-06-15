import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from pyspark.sql import functions as F
from pyspark.sql.types import StructType, StructField, StringType, DoubleType

args = getResolvedOptions(sys.argv, [
    'JOB_NAME', 'target_bucket', 'target_prefix',
    'msk_bootstrap_servers', 'topic_name', 'msk_connection_name',
    'window_size', 'consumer_group_prefix'
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session

target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"
window_size = args.get('window_size', '60 seconds')

# Schema dos alertas
schema = StructType([
    StructField("alerta_id", StringType()),
    StructField("cliente_id", StringType()),
    StructField("conta_id", StringType()),
    StructField("severidade", StringType()),
    StructField("status", StringType()),
    StructField("pais", StringType()),
    StructField("motivo", StringType()),
    StructField("score_risco", DoubleType()),
    StructField("data_alerta", StringType()),
])

# Lê do MSK via Spark Structured Streaming
df_raw = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", args['msk_bootstrap_servers'])
    .option("subscribe", args['topic_name'])
    # Keep Spark-managed unique groups, but make the prefix explicit for observability.
    .option("groupIdPrefix", args['consumer_group_prefix'])
    .option("startingOffsets", "earliest")
    .option("kafka.security.protocol", "SASL_SSL")
    .option("kafka.sasl.mechanism", "AWS_MSK_IAM")
    .option("kafka.sasl.jaas.config",
            "software.amazon.msk.auth.iam.IAMLoginModule required;")
    .option("kafka.sasl.client.callback.handler.class",
            "software.amazon.msk.auth.iam.IAMClientCallbackHandler")
    .load()
)

# Parse JSON do value
df_parsed = (
    df_raw
    .selectExpr("CAST(value AS STRING) as json_str")
    .select(F.from_json(F.col("json_str"), schema).alias("data"))
    .select("data.*")
)

# Escreve micro-batch como Parquet particionado por pais
checkpoint_path = f"s3://{args['target_bucket']}/checkpoints/{args['target_prefix']}/"

query = (
    df_parsed.writeStream
    .format("parquet")
    .option("checkpointLocation", checkpoint_path)
    .option("path", target_path)
    .partitionBy("pais")
    .trigger(processingTime=window_size)
    .start()
)

# Streaming job roda continuamente ate ser parado
query.awaitTermination()
