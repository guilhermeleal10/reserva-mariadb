"""Consumidor RabbitMQ: chama a rotina transacional de criacao de reserva."""
from __future__ import annotations

import hashlib
import json
import logging
import os
import time
from typing import Any

import pika
import pymysql
from pymysql.cursors import DictCursor

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
LOG = logging.getLogger("reservas-worker")


def env(name: str, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if value is None or value == "":
        raise RuntimeError(f"Variavel de ambiente obrigatoria ausente: {name}")
    return value


def connect_db():
    return pymysql.connect(
        host=env("DB_HOST", "db"),
        port=int(env("DB_PORT", "3306")),
        user=env("DB_USER", "reservas_app"),
        password=env("DB_PASSWORD"),
        database=env("DB_NAME", "reservas"),
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=True,  # A procedure controla sua propria transacao.
        connect_timeout=8,
        read_timeout=20,
        write_timeout=20,
    )


def canonical_hash(payload: dict[str, Any]) -> str:
    canonical = json.dumps(
        payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def validate_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("O corpo da mensagem deve ser um objeto JSON.")

    required = ("message_id", "usuario_id", "recurso_id", "inicio", "fim")
    missing = [key for key in required if key not in payload]
    if missing:
        raise ValueError("Campos obrigatorios ausentes: " + ", ".join(missing))

    if not isinstance(payload["message_id"], str) or not payload["message_id"].strip():
        raise ValueError("message_id deve ser um texto nao vazio.")

    try:
        payload["usuario_id"] = int(payload["usuario_id"])
        payload["recurso_id"] = int(payload["recurso_id"])
    except (TypeError, ValueError) as exc:
        raise ValueError("usuario_id e recurso_id devem ser numeros inteiros.") from exc

    payload.setdefault("observacao", None)
    if payload["observacao"] is not None:
        payload["observacao"] = str(payload["observacao"])[:500]
    return payload


def process_message(channel, method, properties, body: bytes) -> None:
    """ACK apenas depois que a procedure confirmou o COMMIT."""
    try:
        payload = validate_payload(json.loads(body.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        LOG.error("Mensagem invalida; descartando sem reprocessar: %s", exc)
        channel.basic_ack(delivery_tag=method.delivery_tag)
        return

    msg_id = payload["message_id"]
    digest = canonical_hash(payload)

    try:
        with connect_db() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "CALL sp_criar_reserva(%s, %s, %s, %s, %s, %s, %s)",
                    (
                        msg_id,
                        digest,
                        payload["usuario_id"],
                        payload["recurso_id"],
                        payload["inicio"],
                        payload["fim"],
                        payload["observacao"],
                    ),
                )
                result = cursor.fetchone()
                # Limpa todos os result sets da procedure antes de devolver a conexao.
                while cursor.nextset():
                    cursor.fetchall()

        LOG.info("message_id=%s resultado=%s reserva_id=%s",
                 msg_id,
                 result.get("processamento") if result else "SEM_RESULTADO",
                 result.get("reserva_id") if result else None)
        # A procedure so retorna apos COMMIT ou apos identificar duplicidade.
        channel.basic_ack(delivery_tag=method.delivery_tag)

    except pymysql.MySQLError as exc:
        code = exc.args[0] if exc.args else None
        # Erros de regra de negocio/dados invalidos nao devem ficar em loop na fila.
        permanent_codes = {1062, 1292, 1366, 1451, 1452, 1644}
        if code in permanent_codes:
            LOG.warning("Mensagem rejeitada (codigo MariaDB %s): %s", code, exc)
            channel.basic_ack(delivery_tag=method.delivery_tag)
        else:
            LOG.exception("Falha possivelmente temporaria no banco; mensagem sera reenfileirada")
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)

    except Exception:
        LOG.exception("Falha inesperada; mensagem sera reenfileirada")
        channel.basic_nack(delivery_tag=method.delivery_tag, requeue=True)


def rabbit_connection():
    credentials = pika.PlainCredentials(
        env("RABBITMQ_USER", "reservas"), env("RABBITMQ_PASSWORD")
    )
    parameters = pika.ConnectionParameters(
        host=env("RABBITMQ_HOST", "fila"),
        port=int(env("RABBITMQ_PORT", "5672")),
        virtual_host="/",
        credentials=credentials,
        heartbeat=30,
        blocked_connection_timeout=30,
        connection_attempts=5,
        retry_delay=3,
    )
    return pika.BlockingConnection(parameters)


def main() -> None:
    queue_name = env("RABBITMQ_QUEUE", "reservas.solicitacoes")
    while True:
        try:
            connection = rabbit_connection()
            channel = connection.channel()
            channel.basic_qos(prefetch_count=1)
            channel.basic_consume(
                queue=queue_name,
                on_message_callback=process_message,
                auto_ack=False,
            )
            LOG.info("Aguardando mensagens na fila %s", queue_name)
            channel.start_consuming()
        except KeyboardInterrupt:
            LOG.info("Worker encerrado pelo usuario")
            break
        except Exception:
            LOG.exception("Nao foi possivel manter conexao com RabbitMQ; nova tentativa em 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
