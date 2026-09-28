@echo off
REM Destruicao completa com validacao de erros e limpeza de versoes S3.
REM Dependencias: Python 3.9+, AWS CLI e Terraform.
setlocal
if "%ENV%"=="" set ENV=dev
python "%~dp0scripts\cleanup-lab.py" --environment "%ENV%" %*
exit /b %errorlevel%
