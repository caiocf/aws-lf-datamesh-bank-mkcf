@echo off
REM Gera o layer zip com kafka-python-ng + aws-msk-iam-sasl-signer para Lambda Python 3.12
REM Execute este script ANTES do terraform apply

cd /d "%~dp0"

if exist build rmdir /s /q build
mkdir build\python

pip install kafka-python-ng aws-msk-iam-sasl-signer-python -t build\python --quiet
REM Remove pacotes ja presentes no runtime Lambda
rmdir /s /q build\python\boto3 2>nul
rmdir /s /q build\python\botocore 2>nul
rmdir /s /q build\python\s3transfer 2>nul
rmdir /s /q build\python\urllib3 2>nul
rmdir /s /q build\python\jmespath 2>nul
rmdir /s /q build\python\dateutil 2>nul
rmdir /s /q build\python\click 2>nul
rmdir /s /q build\python\colorama 2>nul
for /d %%i in (build\python\*dist-info) do (
  echo %%i | findstr /i "boto3 botocore s3transfer urllib3 jmespath dateutil click colorama six" >nul && rmdir /s /q "%%i"
)
del /q build\python\six.py 2>nul

cd build
tar -acf ..\kafka_iam_layer.zip python
cd ..

rmdir /s /q build

echo.
echo Layer gerado: kafka_iam_layer.zip
echo.
