-- Cartão fidelidade Cherie Be.
-- O site nunca acessa as tabelas: só chama as funções cartao_* no final deste arquivo.
-- Um selo por dia (fuso de São Paulo) e o limite de 10 são garantidos aqui, no servidor.

create table public.clientes (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 3 and 120),
  telefone text not null unique check (telefone ~ '^[1-9][0-9]{9,10}$'),
  criado_em timestamptz not null default now(),
  consentimento_em timestamptz not null
);

create table public.selos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes (id) on delete cascade,
  data date not null,
  criado_em timestamptz not null default now(),
  unique (cliente_id, data)
);

create table public.resgates (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null references public.clientes (id) on delete cascade,
  criado_em timestamptz not null default now(),
  validado_por text
);

create index resgates_cliente_idx on public.resgates (cliente_id, criado_em desc);

alter table public.clientes enable row level security;
alter table public.selos enable row level security;
alter table public.resgates enable row level security;

revoke all on public.clientes, public.selos, public.resgates from public, anon, authenticated;

-- Selos do cartão atual: os que vieram depois do último resgate.
create function public._cartao_estado(p_cliente uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'nome', c.nome,
    'telefone', c.telefone,
    'selos', coalesce((
      select jsonb_agg(s.data order by s.data)
      from public.selos s
      where s.cliente_id = c.id
        and s.criado_em > coalesce(
          (select max(r.criado_em) from public.resgates r where r.cliente_id = c.id),
          '-infinity'::timestamptz)
    ), '[]'::jsonb)
  )
  from public.clientes c
  where c.id = p_cliente;
$$;

-- Cria o cartão ou devolve o que já existe para aquele WhatsApp.
create function public.cartao_entrar(p_nome text, p_telefone text, p_aceite boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_novo boolean := false;
  v_nome text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
begin
  if p_telefone is null or p_telefone !~ '^[1-9][0-9]{9,10}$' then
    return jsonb_build_object('status', 'telefone_invalido');
  end if;

  select id into v_id from public.clientes where telefone = p_telefone;

  if v_id is null then
    if p_aceite is not true then
      return jsonb_build_object('status', 'sem_aceite');
    end if;
    if char_length(v_nome) not between 3 and 120 or position(' ' in v_nome) = 0 then
      return jsonb_build_object('status', 'nome_invalido');
    end if;

    insert into public.clientes (nome, telefone, consentimento_em)
    values (v_nome, p_telefone, now())
    on conflict (telefone) do nothing
    returning id into v_id;

    if v_id is null then
      select id into v_id from public.clientes where telefone = p_telefone;
    else
      v_novo := true;
    end if;
  end if;

  return public._cartao_estado(v_id)
    || jsonb_build_object('status', 'ok', 'novo', v_novo);
end;
$$;

-- Abre o cartão de quem já está identificada neste navegador.
create function public.cartao_ver(p_telefone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.clientes where telefone = p_telefone;
  if v_id is null then
    return jsonb_build_object('status', 'sem_cadastro');
  end if;
  return public._cartao_estado(v_id) || jsonb_build_object('status', 'ok');
end;
$$;

-- Dá o selo do dia. A data vem sempre do relógio do servidor.
create function public.cartao_carimbar(p_telefone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_estado jsonb;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  -- Trava a cliente para dois toques simultâneos não passarem de 10 selos.
  select id into v_id from public.clientes where telefone = p_telefone for update;
  if v_id is null then
    return jsonb_build_object('status', 'sem_cadastro');
  end if;

  v_estado := public._cartao_estado(v_id);
  if jsonb_array_length(v_estado -> 'selos') >= 10 then
    return v_estado || jsonb_build_object('status', 'completo');
  end if;

  if exists (select 1 from public.selos where cliente_id = v_id and data = v_hoje) then
    return v_estado || jsonb_build_object('status', 'ja_hoje');
  end if;

  insert into public.selos (cliente_id, data) values (v_id, v_hoje);
  return public._cartao_estado(v_id) || jsonb_build_object('status', 'ok');
end;
$$;

-- "Já resgatei": registra o resgate e abre um cartão novo. Só vale com 10 selos.
create function public.cartao_novo(p_telefone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.clientes where telefone = p_telefone for update;
  if v_id is null then
    return jsonb_build_object('status', 'sem_cadastro');
  end if;

  if jsonb_array_length(public._cartao_estado(v_id) -> 'selos') < 10 then
    return public._cartao_estado(v_id) || jsonb_build_object('status', 'incompleto');
  end if;

  insert into public.resgates (cliente_id) values (v_id);
  return public._cartao_estado(v_id) || jsonb_build_object('status', 'ok');
end;
$$;

revoke all on function public._cartao_estado(uuid) from public, anon, authenticated;
revoke all on function public.cartao_entrar(text, text, boolean) from public;
revoke all on function public.cartao_ver(text) from public;
revoke all on function public.cartao_carimbar(text) from public;
revoke all on function public.cartao_novo(text) from public;

grant execute on function public.cartao_entrar(text, text, boolean) to anon;
grant execute on function public.cartao_ver(text) to anon;
grant execute on function public.cartao_carimbar(text) to anon;
grant execute on function public.cartao_novo(text) to anon;
