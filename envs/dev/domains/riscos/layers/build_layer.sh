#!/bin/bash
# Gera o layer zip com kafka-python-ng + aws-msk-iam-sasl-signer para Lambda Python 3.12
# Execute este script ANTES do terraform apply

set -e
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/python

pip install kafka-python-ng aws-msk-iam-sasl-signer-python \
  -t build/python --quiet

# Remove pacotes ja presentes no runtime Lambda
rm -rf build/python/boto3* build/python/botocore* build/python/s3transfer*
rm -rf build/python/urllib3* build/python/jmespath* build/python/dateutil*
rm -rf build/python/click* build/python/colorama* build/python/six*
rm -rf build/python/python_dateutil* build/python/__pycache__ build/python/bin

cd build
zip -r ../kafka_iam_layer.zip python
cd ..

rm -rf build

echo ""
echo "Layer gerado: kafka_iam_layer.zip"
