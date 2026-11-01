USE reservas;

-- 1) Reserva inicial: deve retornar CRIADA.
CALL sp_criar_reserva(
    'demo-msg-001',
    SHA2('ana|sala01|2026-11-03 09:00|2026-11-03 10:00', 256),
    1, 1,
    '2026-11-03 09:00:00',
    '2026-11-03 10:00:00',
    'Aula demonstrativa'
);

-- 2) Mesmo recurso e periodo sobreposto: deve retornar REJEITADA.
CALL sp_criar_reserva(
    'demo-msg-002',
    SHA2('ana|sala01|2026-11-03 09:30|2026-11-03 10:30', 256),
    1, 1,
    '2026-11-03 09:30:00',
    '2026-11-03 10:30:00',
    'Tentativa de horario conflitante'
);

-- 3) Periodos adjacentes: deve retornar CRIADA (10:00-11:00).
CALL sp_criar_reserva(
    'demo-msg-003',
    SHA2('ana|sala01|2026-11-03 10:00|2026-11-03 11:00', 256),
    1, 1,
    '2026-11-03 10:00:00',
    '2026-11-03 11:00:00',
    'Reserva imediatamente posterior'
);

-- 4) Reenvio da primeira mensagem: deve retornar DUPLICADA, sem criar outra reserva.
CALL sp_criar_reserva(
    'demo-msg-001',
    SHA2('ana|sala01|2026-11-03 09:00|2026-11-03 10:00', 256),
    1, 1,
    '2026-11-03 09:00:00',
    '2026-11-03 10:00:00',
    'Aula demonstrativa'
);

-- Confira os resultados e o total de reservas.
SELECT id, usuario_id, recurso_id, inicio, fim, status
FROM reserva
ORDER BY inicio;

SELECT message_id, status, reserva_id, resultado
FROM mensagem_idempotencia
ORDER BY recebida_em;
