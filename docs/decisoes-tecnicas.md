# Registro de decisões técnicas

> Ajustem este registro ao que o grupo realmente implementar e defender. Cada decisão deve ser explicada com motivo, alternativa e impacto no banco.

| # | Decisão | Motivo | Alternativa considerada | Impacto no banco |
|---|---|---|---|---|
| 1 | Usar MariaDB com InnoDB | Precisamos de transações, chaves estrangeiras e recuperação consistente. | Banco em memória ou tabelas sem mecanismo transacional. | As tabelas usam InnoDB; operações de reserva podem fazer COMMIT/ROLLBACK e respeitam FKs. |
| 2 | Separar usuario, recurso e reserva | Um usuário pode fazer várias reservas; um recurso pode aparecer em várias reservas ao longo do tempo. | Guardar nome do usuário e do recurso diretamente em cada reserva. | Evita repetição de dados e permite FKs para manter integridade referencial. |
| 3 | Bloquear a linha do recurso com SELECT ... FOR UPDATE antes da checagem | Dois pedidos simultâneos para o mesmo recurso precisam ser serializados. | Fazer apenas um SELECT de disponibilidade na aplicação. | A linha de recurso funciona como mutex transacional; o segundo pedido espera o primeiro concluir e depois revalida o período. |
| 4 | Usar intervalos semiabertos [inicio, fim) | Permite uma reserva terminar às 10h e outra começar às 10h sem conflito. | Considerar o horário final como inclusivo. | A condição de conflito é inicio_existente < fim_novo e fim_existente > inicio_novo. |
| 5 | Manter CANCELADA como status, sem apagar a reserva | Preserva histórico e permite auditoria. | Excluir a linha quando alguém cancelar. | A consulta de conflito ignora reservas canceladas; os dados históricos continuam disponíveis. |
| 6 | Usar RabbitMQ como fila durável de solicitações | Desacopla a chegada dos pedidos do processamento, absorve picos e permite retentativas. | A API gravar tudo diretamente e de forma síncrona. | O banco continua sendo a fonte da verdade; o worker só confirma a mensagem depois do COMMIT. |
| 7 | Usar message_id único e payload_hash | Uma fila pode entregar a mesma mensagem novamente; repetir o efeito não pode criar duas reservas. | Confiar que cada mensagem será entregue uma única vez. | A PK de mensagem_id registra o processamento; reenvios retornam o resultado anterior. |
| 8 | Manter o banco em volume Docker nomeado | Os dados precisam sobreviver à recriação do contêiner. | Armazenar os arquivos apenas na camada gravável do contêiner. | O diretório de dados fica no volume mariadb_data; remover o contêiner não remove o volume. |
| 9 | Usar FK, CHECK e índices | Regras simples devem ser validadas no próprio banco e as consultas de disponibilidade precisam de apoio. | Validar tudo somente no código da aplicação. | CHECK impede fim <= inicio; FKs impedem referências inválidas; índices auxiliam buscas por recurso/período. |

## Regra de concorrência que deve ser defendida

A fila organiza a entrada e o worker controla a confirmação da mensagem, mas a proteção definitiva contra sobreposição está no banco: a rotina `sp_criar_reserva` abre uma transação e bloqueia a linha do recurso com `SELECT ... FOR UPDATE`. Assim, dois workers que tentem reservar o mesmo recurso não conseguem passar pela validação ao mesmo tempo. Depois do bloqueio, o worker consulta os períodos ativos com:

```sql
inicio_existente < fim_novo
AND fim_existente > inicio_novo
```

Se houver conflito, a solicitação é rejeitada. Caso contrário, a reserva e o registro de idempotência são gravados na mesma transação.

## Limitação assumida

A rotina `sp_criar_reserva` deve ser o caminho usado para criar reservas. Se outro código inserir diretamente na tabela `reserva`, ignorando o bloqueio por recurso, poderá quebrar a regra de não sobreposição. Em um sistema real, o usuário do banco usado pela aplicação deve receber somente as permissões necessárias, e as gravações devem passar pela rotina ou por um serviço que implemente exatamente o mesmo protocolo.
