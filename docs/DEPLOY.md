# Deploy passo a passo

## 1. Login AWS

Exemplo com profile:

```bash
export AWS_PROFILE=seu-profile
aws sts get-caller-identity
```

## 2. Foundation

```bash
cd envs/dev/foundation
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Guarde os outputs:

```bash
terraform output consumer_role_arns
terraform output athena_workgroups
```

## 3. Domínio Clientes

```bash
cd ../domains/clientes
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

## 4. Próximos domínios

```bash
cd ../contas && terraform init && terraform apply
cd ../transacoes && terraform init && terraform apply
cd ../parceiros && terraform init && terraform apply
cd ../alertas && terraform init && terraform apply
```

## 5. Teste no Athena

Entre na AWS Console, assuma uma das roles consumidoras, escolha o workgroup e execute:

```sql
SELECT * FROM dl_dev_clientes.cliente_360;
```

## 6. Destruição

Destrua os domínios primeiro, depois a foundation:

```bash
cd envs/dev/domains/alertas && terraform destroy
cd ../parceiros && terraform destroy
cd ../transacoes && terraform destroy
cd ../contas && terraform destroy
cd ../clientes && terraform destroy
cd ../../foundation && terraform destroy
```
