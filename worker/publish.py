"""Publica uma solicitacao de reserva persistente na fila RabbitMQ."""
from __future__ import annotations

import argparse
import json
import os
import uuid

import pika


def env(name: str, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if value is None or value == "":
        raise RuntimeError(f"Variavel de ambiente obrigatoria ausente: {name}")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description="Publica uma solicitacao na fila de reservas")
    parser.add_argument("--usuario", type=int, required=True)
    parser.add_argument("--recurso", type=int, required=True)
    parser.add_argument("--inicio", required=True, help="AAAA-MM-DD HH:MM:SS")
    parser.add_argument("--fim", required=True, help="AAAA-MM-DD HH:MM:SS")
    parser.add_argument("--observacao", default=None)
    parser.add_argument("--message-id", default=None,
                        help="Informe o mesmo ID novamente para testar idempotencia")
    args = parser.parse_args()

    message_id = args.message_id or str(uuid.uuid4())
    payload = {
        "message_id": message_id,
        "usuario_id": args.usuario,
        "recurso_id": args.recurso,
        "inicio": args.inicio,
        "fim": args.fim,
        "observacao": args.observacao,
    }
    body = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

    credentials = pika.PlainCredentials(
        env("RABBITMQ_USER", "reservas"), env("RABBITMQ_PASSWORD")
    )
    parameters = pika.ConnectionParameters(
        host=env("RABBITMQ_HOST", "fila"),
        port=int(env("RABBITMQ_PORT", "5672")),
        virtual_host="/",
        credentials=credentials,
        heartbeat=30,
        connection_attempts=5,
        retry_delay=2,
    )

    connection = pika.BlockingConnection(parameters)
    try:
        channel = connection.channel()
        channel.confirm_delivery()
        published = channel.basic_publish(
            exchange="reservas.exchange",
            routing_key="reserva.solicitar",
            body=body,
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=2,  # mensagem persistente
                message_id=message_id,
            ),
            mandatory=True,
        )
        if published is False:
            raise RuntimeError("RabbitMQ nao confirmou a publicacao")
        print(f"Mensagem publicada. message_id={message_id}")
    finally:
        connection.close()


if __name__ == "__main__":
    main()
