# Registro do uso crítico da IA

A atividade pede pelo menos três usos da IA e o registro **prompt → recomendação → decisão do grupo → justificativa**. Não inventem respostas que não foram recebidas: copiem a resposta real usada pelo grupo e expliquem se aceitaram ou rejeitaram a sugestão.

## Uso 1 — revisão inicial da arquitetura

**Prompt obrigatório da atividade:**

> Você será nosso revisor de arquitetura. Não desenhe a solução nem produza um componente completo. Faça perguntas, encontre inconsistências e mostre consequências. Ao sugerir tecnologia, explique qual problema concreto ela resolve. Foco: Banco de Dados II.

**Recomendação recebida da IA:** preencher com a resposta real.

**Decisão do grupo:** definir os componentes que realmente serão mantidos no diagrama.

**Justificativa:** cada componente deve resolver uma necessidade concreta do fluxo; não incluir tecnologia apenas por ser moderna.

## Uso 2 — revisão da regra de concorrência

**Prompt sugerido:**

> Revise nossa regra de reserva: o mesmo recurso não pode ter dois períodos sobrepostos, inclusive quando dois pedidos chegam quase ao mesmo tempo. Avalie a condição de conflito, o uso de transação e SELECT FOR UPDATE no MariaDB. Aponte falhas e explique os cenários de corrida. Não substitua a decisão do grupo.

**Recomendação recebida da IA:** preencher com a resposta real.

**Decisão do grupo:** usar uma transação e bloquear a linha do recurso antes de consultar os conflitos.

**Justificativa:** uma consulta simples seguida de INSERT pode permitir que dois pedidos simultâneos enxerguem o mesmo horário como livre. O bloqueio serializa a decisão por recurso.

## Uso 3 — revisão de fila e idempotência

**Prompt sugerido:**

> Revise o fluxo RabbitMQ → worker → MariaDB. Considere que uma mensagem pode ser entregue novamente se o worker confirmar o COMMIT e falhar antes do ACK. Como evitar duas reservas para a mesma mensagem? Avalie message_id único, hash do conteúdo e o momento correto do ACK. Aponte limites da solução.

**Recomendação recebida da IA:** preencher com a resposta real.

**Decisão do grupo:** registrar cada message_id em mensagem_idempotencia, com hash do conteúdo e resultado do processamento; confirmar a mensagem somente depois do COMMIT.

**Justificativa:** se houver reentrega, o identificador já estará registrado e o sistema devolve o resultado anterior em vez de repetir o efeito.
