-- Seed base: garante que as 10 contas existam
INSERT INTO contas (conta_id, cliente_id, tipo_conta, saldo, status, pais) VALUES
('a001', 'c001', 'corrente', 15000.50, 'ativa', 'BR'),
('a002', 'c002', 'poupanca', 2500.00, 'ativa', 'BR'),
('a003', 'c003', 'corrente', 8000.00, 'ativa', 'US'),
('a004', 'c004', 'corrente', 12000.00, 'ativa', 'BR'),
('a005', 'c005', 'poupanca', 3500.00, 'encerrada', 'BR'),
('a006', 'c006', 'corrente', 25000.00, 'ativa', 'US'),
('a007', 'c007', 'corrente', 9000.00, 'ativa', 'AR'),
('a008', 'c008', 'poupanca', 1500.00, 'ativa', 'AR'),
('a009', 'c009', 'corrente', 18000.00, 'ativa', 'DE'),
('a010', 'c010', 'corrente', 7500.00, 'ativa', 'DE')
ON CONFLICT (conta_id) DO UPDATE SET
    saldo = EXCLUDED.saldo + (random() * 1000)::decimal(12,2),
    status = EXCLUDED.status;

-- Inserts incrementais: gera novas contas com ID curto baseado em timestamp
-- Cada execucao cria 5 contas novas (nunca colide com anteriores)
INSERT INTO contas (conta_id, cliente_id, tipo_conta, saldo, status, pais)
SELECT
    'x' || lpad(((extract(epoch from now())::bigint % 100000) * 10 + s.i)::text, 9, '0'),
    'c' || lpad((floor(random() * 100) + 1)::text, 3, '0'),
    CASE WHEN random() > 0.5 THEN 'corrente' ELSE 'poupanca' END,
    (random() * 50000)::decimal(12,2),
    'ativa',
    (ARRAY['BR','BR','BR','US','AR','DE'])[floor(random() * 6 + 1)::int]
FROM generate_series(1, 5) AS s(i)
ON CONFLICT (conta_id) DO NOTHING;

-- Updates de saldo: simula movimentacoes nas contas existentes (gera CDC updates)
UPDATE contas
SET saldo = saldo + (random() * 2000 - 1000)::decimal(12,2)
WHERE status = 'ativa'
  AND random() < 0.5;
