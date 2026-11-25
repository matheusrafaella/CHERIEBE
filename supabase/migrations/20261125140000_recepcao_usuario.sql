-- A página da recepção pede só a senha e entra sempre com este usuário fixo.
-- O usuário e a senha são criados no painel do Supabase (Authentication > Users),
-- com "Auto Confirm User" marcado. Aqui ele só recebe permissão de leitura.
insert into public.equipe (email) values ('recepcao@cheriebe.com.br')
on conflict (email) do nothing;
