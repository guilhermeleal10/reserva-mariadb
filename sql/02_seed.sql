USE reservas;

-- Usuário de demonstração. O valor abaixo é apenas um marcador, NÃO é uma senha
-- válida nem deve ser usado em um sistema real. Uma aplicação deve gerar hash
-- seguro (por exemplo, bcrypt ou Argon2) antes de salvar a senha.
INSERT INTO usuario (nome, email, senha_hash, perfil)
VALUES ('Ana Souza', 'ana@demo.local', 'HASH_DE_DEMO_NAO_UTILIZAR', 'USUARIO');

INSERT INTO recurso (nome, tipo, descricao, localizacao, capacidade, status)
VALUES
    ('Sala 01', 'SALA', 'Sala de reunioes para demonstracao', 'Bloco A', 12, 'ATIVO'),
    ('Laboratorio 01', 'LABORATORIO', 'Laboratorio de informatica', 'Bloco B', 30, 'ATIVO'),
    ('Projetor 01', 'EQUIPAMENTO', 'Projetor multimidia', 'Almoxarifado', NULL, 'ATIVO');
