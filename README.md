# Sistema de Reservas — Banco de Dados II

Projeto-base para a atividade de modelagem de reservas com Docker, MariaDB, integridade, fila e recuperação.

## 1. Cenário e regra de negócio

Uma instituição precisa controlar salas, laboratórios, equipamentos, usuários e reservas. O mesmo recurso não pode ter duas reservas com períodos sobrepostos, inclusive quando dois pedidos chegam quase ao mesmo tempo.

O modelo considera os períodos como semiabertos `[início, fim)`. Portanto, uma reserva das 09:00 às 10:00 e outra das 10:00 às 11:00 são permitidas. Uma reserva das 09:30 às 10:30 conflita com a primeira.

## 2. Componentes e fluxo

- **Usuário:** solicita uma reserva.
- **API/aplicação:** valida os dados básicos e publica uma mensagem persistente.
- **RabbitMQ:** mantém a fila durável `reservas.solicitacoes` (exchange `reservas.exchange`, chave `reserva.solicitar`) e permite absorver picos e retentativas.
- **Worker:** consome a mensagem, chama a rotina no banco e só confirma a mensagem depois do COMMIT.
- **MariaDB/InnoDB:** armazena os dados e toma a decisão definitiva de disponibilidade.

O Compose sobe MariaDB, RabbitMQ e um worker funcional. Para manter o escopo pequeno, não há uma interface web/API completa: o arquivo `worker/publish.py` atua como produtor de teste, publica solicitações na fila e o worker as processa.

Diagrama de arquitetura: `docs/diagrama-arquitetura.mmd`.

## 3. Modelo de dados

- `usuario`: pessoas autorizadas a solicitar reservas.
- `recurso`: sala, laboratório ou equipamento que pode ser reservado.
- `reserva`: vínculo entre usuário e recurso, com período e situação.
- `mensagem_idempotencia`: controla o processamento de cada mensagem da fila.

Diagrama ER: `docs/diagrama-er.mmd`.

### Integridade

- PKs identificam cada registro.
- FKs ligam reservas a usuários e recursos.
- `CHECK (fim > inicio)` impede intervalo inválido.
- `UNIQUE (email)` impede cadastro duplicado de e-mail.
- Índices apoiam as consultas de disponibilidade e histórico.
- `ON DELETE RESTRICT` evita apagar um usuário ou recurso que possua reservas históricas.

## 4. Como executar

É necessário ter Docker Desktop (ou Docker Engine) com o comando `docker compose` disponível.

1. Copie `.env.example` para `.env`.
2. Edite `.env` e troque todas as senhas de exemplo.
3. Abra um terminal na pasta do projeto.
4. Execute:

```bash
docker compose up -d --build
```

Confira os serviços:

```bash
docker compose ps
docker compose logs -f db
```

Conecte ao banco:

```bash
docker compose exec db mariadb -u reservas_app -p reservas
```

A senha solicitada é o valor de `DB_APP_PASSWORD` definido no `.env`.

### Publicar solicitações pela fila

Com os serviços iniciados, publique um pedido de demonstração:

```bash
docker compose exec worker python publish.py --usuario 1 --recurso 1 --inicio "2026-11-04 09:00:00" --fim "2026-11-04 10:00:00" --message-id teste-001
```

O worker consumirá a mensagem, verificará a disponibilidade no MariaDB e gravará o resultado. Acompanhe o processamento:

```bash
docker compose logs -f worker
```

Para testar a sobreposição, publique outro pedido no mesmo recurso, com período cruzado e outro ID:

```bash
docker compose exec worker python publish.py --usuario 1 --recurso 1 --inicio "2026-11-04 09:30:00" --fim "2026-11-04 10:30:00" --message-id teste-002
```

Para testar idempotência, publique novamente exatamente o primeiro pedido com o mesmo `message-id=teste-001`. O worker deve registrar `DUPLICADA`, sem criar outra reserva. Para testar mensagem duplicada, não altere nenhum outro campo do pedido.

A fila e o exchange são declarados pela configuração em `rabbitmq/definitions.json`. O produtor de teste já publica mensagens persistentes (delivery mode 2) em `reservas.exchange`, com a chave `reserva.solicitar`. A interface de administração do RabbitMQ fica em `http://localhost:15672`. Entre com o usuário e a senha definidos por `RABBITMQ_USER` e `RABBITMQ_PASSWORD` no `.env`.

**Importante:** os arquivos em `sql/` são executados automaticamente apenas quando o volume do banco é criado pela primeira vez. Alterações posteriores no SQL não são aplicadas automaticamente a um volume que já contém dados.

## 5. Teste da regra de reservas

Com o banco iniciado, execute em outro terminal:

```bash
docker compose exec -T db mariadb -u reservas_app -p"SUA_SENHA_DO_ENV" reservas < sql/03_testes.sql
```

Troque `SUA_SENHA_DO_ENV` pela senha real do usuário `reservas_app`. Se preferir, entre no cliente MariaDB e execute os comandos do arquivo `sql/03_testes.sql` manualmente.

Resultados esperados:

1. A reserva 09:00–10:00 é criada.
2. A reserva 09:30–10:30 é rejeitada por sobreposição.
3. A reserva 10:00–11:00 é criada porque é adjacente, mas não sobreposta.
4. O reenvio de `demo-msg-001` retorna `DUPLICADA` e não cria outra reserva.

Para consultar os dados:

```sql
SELECT * FROM reserva ORDER BY inicio;
SELECT * FROM mensagem_idempotencia ORDER BY recebida_em;
```

## 6. Como a concorrência é controlada

A rotina `sp_criar_reserva` inicia uma transação e bloqueia a linha do recurso com `SELECT ... FOR UPDATE`. Só depois verifica se existe reserva ativa cujo início seja anterior ao fim solicitado e cujo fim seja posterior ao início solicitado.

Esse bloqueio é importante: uma simples consulta de disponibilidade seguida de INSERT deixa uma janela em que dois pedidos quase simultâneos podem considerar o mesmo horário livre. O bloqueio por recurso faz o segundo pedido aguardar e verificar novamente depois que o primeiro terminar.

A rotina também grava `message_id` e `payload_hash` na mesma transação da reserva. Se o worker falhar depois do COMMIT e antes do ACK, a fila poderá entregar a mensagem outra vez; o registro de idempotência permite devolver o resultado anterior sem criar uma segunda reserva.

A fila sozinha não substitui o controle transacional do banco. O banco continua sendo a fonte da verdade.

## 7. Fluxo de cancelamento

Para cancelar uma reserva, não apague a linha. Atualize seu status, preservando o histórico:

```sql
UPDATE reserva
   SET status = 'CANCELADA'
 WHERE id = 1
   AND status IN ('PENDENTE', 'CONFIRMADA');
```

A consulta de conflito considera somente `PENDENTE` e `CONFIRMADA`; portanto, reservas canceladas deixam de bloquear o horário. Em uma aplicação real, o cancelamento também deve validar se o usuário tem permissão para cancelar aquela reserva.

## 8. Backup e recuperação

O volume nomeado `mariadb_data` mantém os dados quando o contêiner é removido/recriado. Porém, volume no mesmo computador não substitui backup: falha ou perda do disco pode levar os dois juntos.

Em Linux, macOS, WSL ou Git Bash:

```bash
./scripts/backup.sh
./scripts/restore.sh backups/ARQUIVO_DE_BACKUP.sql
```

A restauração pede confirmação porque pode sobrescrever dados. Guarde cópias fora da máquina e teste a restauração periodicamente.

## 9. Segurança

- Não coloque o arquivo `.env` no Git ou em capturas públicas.
- Não use a conta root na aplicação; utilize `reservas_app`.
- As portas de MariaDB e RabbitMQ estão vinculadas a `127.0.0.1`, evitando exposição direta na rede.
- A aplicação deve guardar hash de senha, nunca senha em texto puro.
- Em produção, use gestão de segredos, TLS, firewall, permissões mínimas e política de backup externo.

## 10. Situações-surpresa: como defender

- **Falha do contêiner:** recriar com `docker compose up -d`; o volume nomeado preserva os dados.
- **Perda do volume:** restaurar o último backup válido; o volume sozinho não resolve perda do disco.
- **100 pedidos iguais:** a fila absorve o pico; `message_id` evita efeito duplicado; o bloqueio por recurso protege contra horários conflitantes.
- **Mensagem duplicada:** worker detecta `message_id` já processado e não repete a gravação.
- **Senha root vazada no Git:** revogar/rotacionar credenciais e tirar segredos do repositório; `.env` está no `.gitignore`.
- **Banco lento:** conferir plano com `EXPLAIN`, índices, volume de dados e consultas; não adicionar tecnologia sem medir o problema.
- **Crescimento de dados:** manter índices e paginação, monitorar desempenho, automatizar backups e só então avaliar novas estratégias.

## 11. Checklist para a entrega

- [ ] Diagrama de arquitetura com componentes e setas explicados.
- [ ] DER com entidades, PK, FK, restrições e índices.
- [ ] `docker-compose.yml` executando MariaDB, RabbitMQ e worker.
- [ ] Teste de reserva válida, conflito, horário adjacente e mensagem duplicada.
- [ ] Backup e recuperação demonstrados.
- [ ] Pelo menos cinco decisões técnicas justificadas em `docs/decisoes-tecnicas.md`.
- [ ] Três usos reais da IA registrados em `docs/uso-da-ia.md`.
- [ ] Todos os integrantes sabem explicar a regra de concorrência e o fluxo da fila.

## 12. Limites deste projeto-base

Este pacote contém MariaDB, RabbitMQ, worker consumidor e produtor de teste pela linha de comando, além de diagramas e documentação. Não contém uma API web, interface de usuário nem autenticação/autorização funcional. O produtor CLI existe para demonstrar o fluxo da fila sem exigir uma aplicação completa, conforme o escopo indicado na aula. Ajustem nomes, decisões e escopo conforme o que o grupo realmente construir.
