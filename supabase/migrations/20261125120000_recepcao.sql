-- Página da recepção (/recepcao): consulta de clientes e selos.
-- Só lê dados quem está logado pelo Supabase Auth, com e-mail confirmado
-- e cadastrado na tabela equipe. Os e-mails da equipe são incluídos pelo painel
-- do Supabase (Table Editor > equipe), nunca por aqui: este repositório é público.

create table public.equipe (
  email text primary key check (email = lower(trim(email))),
  criado_em timestamptz not null default now()
);

alter table public.equipe enable row level security;
revoke all on public.equipe from public, anon, authenticated;

create function public._eh_equipe()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    join public.equipe e on e.email = lower(u.email)
    where u.id = auth.uid()
      and u.email_confirmed_at is not null
  );
$$;

-- Lista de clientes com o cartão atual (selos depois do último resgate).
create function public.recepcao_clientes()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public._eh_equipe() then
    return jsonb_build_object('status', 'sem_acesso');
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'hoje', (now() at time zone 'America/Sao_Paulo')::date,
    'clientes', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.ultimo desc nulls last, x.nome)
      from (
        select
          c.id,
          c.nome,
          c.telefone,
          c.criado_em,
          (select count(*) from public.selos s
            where s.cliente_id = c.id
              and s.criado_em > coalesce(r.ultimo_resgate, '-infinity'::timestamptz))::int as selos,
          (select max(s.data) from public.selos s where s.cliente_id = c.id) as ultimo,
          (select count(*) from public.resgates rr where rr.cliente_id = c.id)::int as resgates
        from public.clientes c
        left join lateral (
          select max(r2.criado_em) as ultimo_resgate
          from public.resgates r2
          where r2.cliente_id = c.id
        ) r on true
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

-- Detalhe de uma cliente: datas do cartão atual, histórico e resgates.
create function public.recepcao_cliente(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ultimo timestamptz;
begin
  if not public._eh_equipe() then
    return jsonb_build_object('status', 'sem_acesso');
  end if;

  if not exists (select 1 from public.clientes where id = p_id) then
    return jsonb_build_object('status', 'nao_encontrada');
  end if;

  select max(criado_em) into v_ultimo from public.resgates where cliente_id = p_id;

  return jsonb_build_object(
    'status', 'ok',
    'cartao', coalesce((
      select jsonb_agg(jsonb_build_object('data', s.data, 'em', s.criado_em) order by s.data)
      from public.selos s
      where s.cliente_id = p_id
        and s.criado_em > coalesce(v_ultimo, '-infinity'::timestamptz)
    ), '[]'::jsonb),
    'historico', (select count(*) from public.selos where cliente_id = p_id)::int,
    'resgates', coalesce((
      select jsonb_agg(jsonb_build_object('em', r.criado_em, 'por', r.validado_por) order by r.criado_em desc)
      from public.resgates r
      where r.cliente_id = p_id
    ), '[]'::jsonb)
  );
end;
$$;

-- O Supabase concede execução a anon e authenticated por padrão: aqui fica explícito.
revoke all on function public._eh_equipe() from public, anon, authenticated;
revoke all on function public.recepcao_clientes() from public, anon, authenticated;
revoke all on function public.recepcao_cliente(uuid) from public, anon, authenticated;
grant execute on function public.recepcao_clientes() to authenticated;
grant execute on function public.recepcao_cliente(uuid) to authenticated;
