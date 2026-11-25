-- Selos do cartão de papel: a recepção lança, na ficha da cliente, quantos selos
-- ela tinha no cartão antigo. Ficam marcados com origem 'cartao_antigo' para conferência.

alter table public.selos
  add column origem text check (origem in ('cartao_antigo'));

-- Define quantos selos do cartão antigo o cartão atual tem (0 a 9).
-- Chamar de novo corrige o número; 0 desfaz o lançamento.
create function public.recepcao_selos_antigos(p_id uuid, p_qtd int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ultimo timestamptz;
  v_novos int;
  v_base date;
  v_dia date;
  v_feitos int := 0;
begin
  if not public._eh_equipe() then
    return jsonb_build_object('status', 'sem_acesso');
  end if;

  if p_qtd is null or p_qtd < 0 or p_qtd > 9 then
    return jsonb_build_object('status', 'quantidade_invalida');
  end if;

  -- Trava a cliente para não cruzar com um check-in no mesmo instante.
  perform 1 from public.clientes where id = p_id for update;
  if not found then
    return jsonb_build_object('status', 'nao_encontrada');
  end if;

  select max(criado_em) into v_ultimo from public.resgates where cliente_id = p_id;

  select count(*) into v_novos
  from public.selos
  where cliente_id = p_id
    and criado_em > coalesce(v_ultimo, '-infinity'::timestamptz)
    and origem is null;

  if v_novos + p_qtd > 10 then
    return jsonb_build_object('status', 'passa_de_10', 'novos', v_novos);
  end if;

  delete from public.selos
  where cliente_id = p_id
    and criado_em > coalesce(v_ultimo, '-infinity'::timestamptz)
    and origem = 'cartao_antigo';

  -- Um selo por dia é regra da tabela: os antigos ganham dias anteriores a todos os outros.
  select least(coalesce(min(data), current_date), (now() at time zone 'America/Sao_Paulo')::date)
    into v_base
  from public.selos where cliente_id = p_id;

  v_dia := v_base;
  while v_feitos < p_qtd loop
    v_dia := v_dia - 1;
    insert into public.selos (cliente_id, data, origem) values (p_id, v_dia, 'cartao_antigo');
    v_feitos := v_feitos + 1;
  end loop;

  return jsonb_build_object('status', 'ok', 'antigos', p_qtd, 'selos', v_novos + p_qtd);
end;
$$;

-- A ficha passa a dizer quais selos vieram do cartão de papel.
create or replace function public.recepcao_cliente(p_id uuid)
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
      select jsonb_agg(jsonb_build_object('data', s.data, 'em', s.criado_em, 'antigo', s.origem = 'cartao_antigo') order by s.data)
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

revoke all on function public.recepcao_selos_antigos(uuid, int) from public, anon, authenticated;
grant execute on function public.recepcao_selos_antigos(uuid, int) to authenticated;
revoke all on function public.recepcao_cliente(uuid) from public, anon, authenticated;
grant execute on function public.recepcao_cliente(uuid) to authenticated;
