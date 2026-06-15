import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.window import Window
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

source_path = f"s3://{args['source_bucket']}/{args['source_prefix']}/"
target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"

# Lê Parquet do bronze (gravado pelo Streaming Job)
df = spark.read.option("basePath", source_path).parquet(source_path)
total = df.count()
print(f"Bronze: {total} registros")

if total == 0:
    print("Nenhum dado. Finalizando.")
else:
    # Deduplica por alerta_id (mais recente por data_alerta vence)
    window = Window.partitionBy("alerta_id").orderBy(F.col("data_alerta").desc())
    df_dedup = (
        df.withColumn("rn", F.row_number().over(window))
          .filter(F.col("rn") == 1)
          .drop("rn")
    )

    print(f"Silver: {df_dedup.count()} alertas unicos")

    # Grava particionado por pais (overwrite)
    df_dedup.write.mode("overwrite").partitionBy("pais").parquet(target_path)
    print("Transformacao bronze -> silver concluida")

job.commit()
