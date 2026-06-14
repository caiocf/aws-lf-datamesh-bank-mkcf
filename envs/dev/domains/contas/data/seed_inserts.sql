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
    cliente_id = EXCLUDED.cliente_id,
    tipo_conta = EXCLUDED.tipo_conta,
    saldo = EXCLUDED.saldo,
    status = EXCLUDED.status,
    pais = EXCLUDED.pais;
