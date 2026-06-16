# Como evoluir este lab para multi-account real

Este lab usa uma unica conta AWS para reduzir custo e complexidade.

Em producao, a evolucao natural seria:

```text
AWS Organizations
├── Data Governance Account
├── Shared Network Account (opcional, se a empresa centralizar conectividade)
├── Domain Clientes Account
├── Domain Contas Account
├── Domain Transacoes Account
├── Domain Parceiros Account
├── Domain Riscos Account
├── Consumer BI Account
├── Consumer Data Science Account
└── Consumer Auditoria Account
```

Mudancas principais:

1. Cada dominio teria provider alias ou estado Terraform separado com credenciais diferentes.
2. Cada conta de dominio teria sua propria baseline de rede: VPC, subnets, route tables e VPC endpoints.
3. Grants Lake Formation usariam principals de outras contas.
4. Compartilhamento cross-account usaria AWS RAM.
5. Contas consumidoras criariam Resource Links no Glue Catalog.
6. Logs iriam para uma Log Archive Account.
7. Security Hub, GuardDuty e Config seriam agregados na Security Account.
8. IAM Identity Center seria a entrada central dos usuarios.

## O que muda em relacao ao lab atual

No lab em conta unica, a camada `envs/dev/network` existe porque `contas`, `transacoes` e `riscos` compartilham a mesma VPC e os mesmos VPC endpoints. Em multi-account real, esse problema deixa de existir porque:

- cada conta de dominio e dona da propria rede
- recursos compartilhados da VPC nao ficam mais dentro do estado Terraform do dominio vizinho
- o boundary entre plataforma e dominio fica mais nitido

Em termos de desenho enterprise, o padrao recomendado continua o mesmo:

- dominio nao deve ser dono de endpoint compartilhado
- rede deve ser provisionada por uma baseline da conta ou do ambiente
- pipeline de dominio deve apenas consumir essa baseline
