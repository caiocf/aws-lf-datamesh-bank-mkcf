# 💰 Guia de Custos - Lake Formation Data Mesh

## 📊 Recursos Criados e Seus Custos

### ✅ **Recursos GRATUITOS (Free Tier)**
- **IAM Roles e Policies** - Sempre gratuito
- **Lake Formation** - Gratuito (apenas control plane)
- **Glue Data Catalog** - Até 1 milhão de objetos gratuitos
- **LF-Tags** - Gratuito
- **Athena Workgroups** - Gratuito (paga apenas por queries)

### 💸 **Recursos com CUSTO MÍNIMO**

#### **S3 Storage**
```
- Buckets vazios: $0
- Objetos CSV pequenos (~1KB cada): ~$0.001/mês
- Total estimado: < $0.10/mês
```

#### **Athena Queries** 
```
- Preço: $5.00 por TB de dados scaneados
- Dados de teste: ~10KB total
- Custo por query: ~$0.00001 (praticamente zero)
```

#### **Glue Tables**
```
- Até 1 milhão de objetos: Gratuito
- Nosso projeto: ~15 tabelas = $0
```

## 🎯 **Custo Total Estimado**

### **Por Mês (recursos ativos)**
```
S3 Storage:           < $0.10
Athena (poucos testes): < $0.05  
Glue Catalog:         $0.00 (Free Tier)
Lake Formation:       $0.00 (Free Tier)
IAM:                  $0.00 (Free Tier)
-------------------------
TOTAL:               < $0.15/mês
```

### **Por Dia**
```
< $0.005/dia (meio centavo por dia!)
```

## ⚠️ **Quando PODE Haver Custo**

### **1. Queries Athena Intensivas**
```
❌ SELECT * FROM tabela_gigante  -- Cara
✅ SELECT col1 FROM tabela LIMIT 10  -- Barata
```

### **2. S3 com Dados Reais**
```
❌ Upload de GBs de dados reais
✅ Apenas CSVs de exemplo (KB)
```

### **3. Glue Jobs (não incluído no projeto)**
```
❌ $0.44/hora por DPU se você criar jobs
✅ Projeto não cria Glue Jobs
```

## 🛡️ **Proteções Implementadas**

### **1. Bucket Policies Restritivas**
- Block public access habilitado
- Apenas roles específicas podem acessar

### **2. Athena com Limites**
- Workgroups com location específico
- Queries limitadas aos dados pequenos

### **3. Sem Serviços Caros**
- ❌ Redshift
- ❌ SageMaker Training
- ❌ Glue Jobs/Crawlers
- ❌ DataZone
- ❌ Macie

## 🚨 **Alertas de Billing (Recomendado)**

Configure alertas no AWS Budgets:

```bash
# Alert se passar de $1/mês
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "lfmesh-study-budget",
    "BudgetLimit": {"Amount": "1", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }'
```

## 🧹 **Limpeza Automática**

### **Diária (automática)**
```bash
# Execute diariamente após estudos
./cleanup.sh
```

### **Semanal (verificação)**
```bash
# Verifique recursos órfãos
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Project,Values=lfmesh
```

## 📈 **Monitoramento de Custos**

### **Via AWS CLI**
```bash
# Custo atual do mês
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost

# Por serviço
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

### **Via Console**
1. **Cost Explorer** → Últimos 30 dias
2. Filtrar por tags: `Project=lfmesh`
3. Agrupar por serviço

## ✅ **Resumo Final**

**Este projeto é EXTREMAMENTE ECONÔMICO:**

- 💚 **Custo mensal: < $0.15**
- 💚 **Foco em aprendizado, não produção**
- 💚 **Scripts de limpeza automática**
- 💚 **Sem recursos caros habilitados**
- 💚 **Free Tier friendly**

**Para estudos de 1-2 semanas: ~$0.02 total** 🎉