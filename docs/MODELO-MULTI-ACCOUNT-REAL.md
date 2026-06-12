# Como evoluir este lab para multi-account real

Este lab usa uma única conta AWS para reduzir custo e complexidade.

Em produção, a evolução natural seria:

```text
AWS Organizations
├── Data Governance Account
├── Domain Clientes Account
├── Domain Contas Account
├── Domain Transacoes Account
├── Domain Parceiros Account
├── Domain Alertas Account
├── Consumer BI Account
├── Consumer Data Science Account
└── Consumer Auditoria Account
```

Mudanças principais:

1. Cada domínio teria provider alias ou estado Terraform separado com credenciais diferentes.
2. Grants Lake Formation usariam principals de outras contas.
3. Compartilhamento cross-account usaria AWS RAM.
4. Contas consumidoras criariam Resource Links no Glue Catalog.
5. Logs iriam para Log Archive Account.
6. Security Hub, GuardDuty e Config seriam agregados na Security Account.
7. IAM Identity Center seria a entrada central dos usuários.
