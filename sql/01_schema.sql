-- Esquema do Sistema de Reservas
-- Executado automaticamente na primeira inicializacao do volume MariaDB.

USE reservas;
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS usuario (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    nome VARCHAR(120) NOT NULL,
    email VARCHAR(190) NOT NULL,
    senha_hash VARCHAR(255) NOT NULL,
    perfil ENUM('ADMIN', 'USUARIO') NOT NULL DEFAULT 'USUARIO',
    ativo BOOLEAN NOT NULL DEFAULT TRUE,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT uq_usuario_email UNIQUE (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS recurso (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    nome VARCHAR(120) NOT NULL,
    tipo ENUM('SALA', 'LABORATORIO', 'EQUIPAMENTO') NOT NULL,
    descricao VARCHAR(500) NULL,
    localizacao VARCHAR(160) NULL,
    capacidade INT UNSIGNED NULL,
    status ENUM('ATIVO', 'MANUTENCAO', 'INATIVO') NOT NULL DEFAULT 'ATIVO',
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT chk_recurso_capacidade CHECK (capacidade IS NULL OR capacidade > 0),
    INDEX idx_recurso_tipo_status (tipo, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS reserva (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    usuario_id BIGINT UNSIGNED NOT NULL,
    recurso_id BIGINT UNSIGNED NOT NULL,
    inicio DATETIME NOT NULL,
    fim DATETIME NOT NULL,
    status ENUM('PENDENTE', 'CONFIRMADA', 'CANCELADA', 'CONCLUIDA', 'REJEITADA') NOT NULL DEFAULT 'PENDENTE',
    observacao VARCHAR(500) NULL,
    criado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    atualizado_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT chk_reserva_periodo CHECK (fim > inicio),
    CONSTRAINT fk_reserva_usuario FOREIGN KEY (usuario_id)
        REFERENCES usuario (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_reserva_recurso FOREIGN KEY (recurso_id)
        REFERENCES recurso (id) ON UPDATE CASCADE ON DELETE RESTRICT,
    INDEX idx_reserva_recurso_periodo (recurso_id, status, inicio, fim),
    INDEX idx_reserva_usuario_inicio (usuario_id, inicio)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Registra o identificador unico de cada mensagem recebida da fila.
-- A chave primaria impede que uma mensagem entregue novamente crie outra reserva.
CREATE TABLE IF NOT EXISTS mensagem_idempotencia (
    message_id VARCHAR(100) NOT NULL,
    payload_hash CHAR(64) NOT NULL,
    status ENUM('PROCESSANDO', 'SUCESSO', 'REJEITADA') NOT NULL DEFAULT 'PROCESSANDO',
    reserva_id BIGINT UNSIGNED NULL,
    resultado VARCHAR(300) NULL,
    recebida_em TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processada_em DATETIME NULL,
    PRIMARY KEY (message_id),
    CONSTRAINT fk_idempotencia_reserva FOREIGN KEY (reserva_id)
        REFERENCES reserva (id) ON UPDATE CASCADE ON DELETE SET NULL,
    INDEX idx_idempotencia_status_data (status, recebida_em)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

DELIMITER //

-- A aplicacao/worker chama esta rotina para criar reservas.
-- IMPORTANTE: a rotina abre e finaliza sua propria transacao. Nao a chame
-- dentro de outra transacao aberta pela aplicacao.
CREATE PROCEDURE sp_criar_reserva(
    IN p_message_id VARCHAR(100),
    IN p_payload_hash CHAR(64),
    IN p_usuario_id BIGINT UNSIGNED,
    IN p_recurso_id BIGINT UNSIGNED,
    IN p_inicio DATETIME,
    IN p_fim DATETIME,
    IN p_observacao VARCHAR(500)
)
proc: BEGIN
    DECLARE v_status_recurso VARCHAR(20) DEFAULT NULL;
    DECLARE v_conflito_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_existe INT DEFAULT 0;
    DECLARE v_hash_existente CHAR(64) DEFAULT NULL;
    DECLARE v_status_existente VARCHAR(20) DEFAULT NULL;
    DECLARE v_reserva_existente BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_nova_reserva BIGINT UNSIGNED DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_message_id IS NULL OR p_message_id = '' OR p_payload_hash IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Identificador e hash da mensagem sao obrigatorios.';
    END IF;

    IF p_inicio IS NULL OR p_fim IS NULL OR p_fim <= p_inicio THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'O horario final deve ser posterior ao inicial.';
    END IF;

    START TRANSACTION;

    -- Linha do recurso funciona como mutex: pedidos para o mesmo recurso
    -- sao analisados um de cada vez, inclusive quando chegam simultaneamente.
    SELECT status
      INTO v_status_recurso
      FROM recurso
     WHERE id = p_recurso_id
     FOR UPDATE;

    IF v_status_recurso IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Recurso nao encontrado.';
    END IF;

    IF v_status_recurso <> 'ATIVO' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Recurso indisponivel ou em manutencao.';
    END IF;

    -- Idempotencia: se a mensagem ja foi concluida, devolve o resultado anterior.
    SELECT COUNT(*)
      INTO v_existe
      FROM mensagem_idempotencia
     WHERE message_id = p_message_id;

    IF v_existe > 0 THEN
        SELECT payload_hash, status, reserva_id
          INTO v_hash_existente, v_status_existente, v_reserva_existente
          FROM mensagem_idempotencia
         WHERE message_id = p_message_id;

        IF v_hash_existente <> p_payload_hash THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Message ID reutilizado com conteudo diferente.';
        END IF;

        COMMIT;

        SELECT 'DUPLICADA' AS processamento,
               v_status_existente AS resultado_original,
               v_reserva_existente AS reserva_id;
        LEAVE proc;
    END IF;

    INSERT INTO mensagem_idempotencia
        (message_id, payload_hash, status, resultado)
    VALUES
        (p_message_id, p_payload_hash, 'PROCESSANDO', 'Mensagem recebida');

    -- Intervalos sao tratados como [inicio, fim): 09:00-10:00 e 10:00-11:00
    -- podem coexistir. Ha conflito se inicio_existente < fim_novo
    -- E fim_existente > inicio_novo.
    SELECT id
      INTO v_conflito_id
      FROM reserva
     WHERE recurso_id = p_recurso_id
       AND status IN ('PENDENTE', 'CONFIRMADA')
       AND inicio < p_fim
       AND fim > p_inicio
     ORDER BY inicio
     LIMIT 1
     FOR UPDATE;

    IF v_conflito_id IS NOT NULL THEN
        UPDATE mensagem_idempotencia
           SET status = 'REJEITADA',
               resultado = 'Conflito: o recurso ja possui reserva nesse periodo.',
               processada_em = CURRENT_TIMESTAMP
         WHERE message_id = p_message_id;

        COMMIT;

        SELECT 'REJEITADA' AS processamento,
               'Conflito de horario' AS resultado,
               NULL AS reserva_id;
        LEAVE proc;
    END IF;

    INSERT INTO reserva
        (usuario_id, recurso_id, inicio, fim, status, observacao)
    VALUES
        (p_usuario_id, p_recurso_id, p_inicio, p_fim, 'CONFIRMADA', p_observacao);

    SET v_nova_reserva = LAST_INSERT_ID();

    UPDATE mensagem_idempotencia
       SET status = 'SUCESSO',
           reserva_id = v_nova_reserva,
           resultado = 'Reserva criada com sucesso.',
           processada_em = CURRENT_TIMESTAMP
     WHERE message_id = p_message_id;

    COMMIT;

    SELECT 'CRIADA' AS processamento,
           'Reserva criada com sucesso.' AS resultado,
           v_nova_reserva AS reserva_id;
END//

DELIMITER ;
