import sys
from uuid import uuid4
import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'source_prefix', 'target_bucket', 'target_prefix'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

source_path = f"s3://{args['source_bucket']}/{args['source_prefix']}/"
target_path = f"s3://{args['target_bucket']}/{args['target_prefix']}/"
staging_path = None

# Le novos arquivos CDC do bronze usando Job Bookmark (transformation_ctx).
# O Glue rastreia quais arquivos ja foram processados.
dyf_new = glueContext.create_dynamic_frame.from_options(
    connection_type="s3",
    format="parquet",
    connection_options={
        "paths": [source_path],
        "recurse": True
    },
    transformation_ctx="cdc_bronze_bookmark"
)

df_new = dyf_new.toDF()
new_count = df_new.count()
print(f"CDC novos (via bookmark): {new_count} registros")

if new_count == 0:
    print("Nenhum dado novo no bronze. Finalizando com sucesso.")
else:
    df_new.printSchema()
    df_new.show(5, truncate=False)

    # Normaliza coluna de operacao do DMS. O Glue Catalog costuma
    # materializar nomes em minusculo, entao aceitamos "Op" e "op".
    if 'Op' in df_new.columns:
        op_column = 'Op'
    elif 'op' in df_new.columns:
        op_column = 'op'
    else:
        op_column = None

    if op_column is None:
        df_new = df_new.withColumn('Op', F.lit('I'))
    else:
        df_new = df_new.withColumn('Op', F.col(op_column))
        df_new = df_new.withColumn('Op', F.when(F.col('Op').isNull(), F.lit('I')).otherwise(F.col('Op')))

    # Only an absent prefix is an empty Silver; do not hide read/access errors.
    existing = boto3.client('s3').list_objects_v2(
        Bucket=args['target_bucket'],
        Prefix=args['target_prefix'].rstrip('/') + '/',
        MaxKeys=1
    )
    if existing.get('KeyCount', 0) > 0:
        df_silver = spark.read.option("basePath", target_path).parquet(target_path)
        silver_count = df_silver.count()
        print(f"Silver existente: {silver_count} registros")
    else:
        print("Silver vazio - primeira execucao")
        df_silver = None

    # 1. Pega deletes do CDC (Op = 'D') - serao removidos do silver.
    deletes = df_new.filter(F.col('Op') == 'D').select('conta_id').distinct()

    # 2. Pega inserts/updates do CDC (Op = 'I' ou 'U') e deduplica por conta_id.
    upserts_raw = df_new.filter(F.col('Op').isin('I', 'U')).drop('Op')

    # Se mesmo conta_id aparece no full load e no CDC, mantem o mais recente.
    if 'dms_timestamp' in upserts_raw.columns:
        window = Window.partitionBy('conta_id').orderBy(F.col('dms_timestamp').desc())
        upserts = (
            upserts_raw.withColumn('rn', F.row_number().over(window))
            .filter(F.col('rn') == 1)
            .drop('rn', 'dms_timestamp')
        )
    else:
        upserts = upserts_raw.dropDuplicates(['conta_id'])

    # 3. Se silver existe, remove os deletados e atualizados antes do merge.
    if df_silver is not None:
        contas_to_remove = deletes.union(upserts.select('conta_id')).distinct()
        df_silver_filtered = df_silver.join(contas_to_remove, on='conta_id', how='left_anti')
        df_merged = df_silver_filtered.unionByName(upserts, allowMissingColumns=True)
    else:
        df_merged = upserts

    # Materialize outside the table prefix before replacing files used by the merge.
    # Keep staging on failure so the complete result remains available for recovery.
    staging_path = f"s3://{args['target_bucket']}/_staging/{args['target_prefix'].strip('/')}/{uuid4().hex}/"
    print(f"Staging do merge: {staging_path}")
    df_merged.write.mode("errorifexists").partitionBy("pais").parquet(staging_path)
    df_staged = spark.read.option("basePath", staging_path).parquet(staging_path)
    staged_count = df_staged.count()
    print(f"Silver (apos CDC merge): {staged_count} registros")
    df_staged.write.mode("overwrite").partitionBy("pais").parquet(target_path)
    written_count = spark.read.option("basePath", target_path).parquet(target_path).count()
    if written_count != staged_count:
        raise RuntimeError(f"Silver incompleta: esperado {staged_count}, gravado {written_count}")

    print("Transformacao bronze -> silver (CDC merge) concluida")

job.commit()

# Cleanup only this run's staging, after data and bookmark have been committed.
if staging_path is not None:
    try:
        staging = sc._jvm.org.apache.hadoop.fs.Path(staging_path)
        if not staging.getFileSystem(sc._jsc.hadoopConfiguration()).delete(staging, True):
            print(f"Aviso: staging mantido para limpeza posterior: {staging_path}")
    except Exception as error:
        print(f"Aviso: falha na limpeza do staging {staging_path}: {error}")
