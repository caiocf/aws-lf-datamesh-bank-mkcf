import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

source_path = f"s3://{args['source_bucket']}/{args['source_prefix']}/"
target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"

# Lê JSON do bronze via Job Bookmark
dyf_new = glueContext.create_dynamic_frame.from_options(
    connection_type="s3",
    format="json",
    connection_options={
        "paths": [source_path],
        "recurse": True
    },
    transformation_ctx="transacoes_bronze_bookmark"
)

df_new = dyf_new.toDF()
new_count = df_new.count()
print(f"Bronze (via S3): {new_count} registros")

if new_count == 0:
    print("Nenhum dado novo. Finalizando.")
else:
    # Tenta ler silver existente para merge
    try:
        df_silver = spark.read.option("basePath", target_path).parquet(target_path)
        silver_count = df_silver.count()
        print(f"Silver existente: {silver_count} registros")
        df_merged = df_new.unionByName(df_silver, allowMissingColumns=True)
    except Exception:
        print("Silver vazio — primeira execução")
        df_merged = df_new

    # Deduplica por transacao_id
    df_dedup = df_merged.dropDuplicates(["transacao_id"])

    print(f"Silver (após dedup): {df_dedup.count()} registros")

    # Grava particionado por pais (overwrite)
    df_dedup.write.mode("overwrite").partitionBy("pais").parquet(target_path)

    print("Transformação bronze → silver concluída")

job.commit()
