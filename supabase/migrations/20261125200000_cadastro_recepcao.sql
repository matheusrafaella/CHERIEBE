-- Cadastro pela recepção: para a cliente que ainda não tem cartão no site.
-- Quando ela entrar no site com o mesmo WhatsApp, cartao_entrar devolve este cartão
-- (a identificação é sempre pelo telefone), com os selos já lançados.

alter table public.clientes
  add column cadastro_por text check (cadastro_por in ('recepcao'));

create function public.recepcao_cadastrar(p_nome text, p_telefone text, p_selos int, p_aceite boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_nome text := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  v_ja record;
begin
  if not public._eh_equipe() then
    return jsonb_build_object('status', 'sem_acesso');
  end if;

  if p_telefone is null or p_telefone !~ '^[1-9][0-9]{9,10}$' then
    return jsonb_build_object('status', 'telefone_invalido');
  end if;
  if char_length(v_nome) not between 3 and 120 or position(' ' in v_nome) = 0 then
    return jsonb_build_object('status', 'nome_invalido');
  end if;
  if p_selos is null or p_selos < 0 or p_selos > 9 then
    return jsonb_build_object('status', 'quantidade_invalida');
  end if;
  -- A recepção confirma que a cliente autorizou guardar nome e WhatsApp (LGPD).
  if p_aceite is not true then
    return jsonb_build_object('status', 'sem_aceite');
  end if;

  select id, nome into v_ja from public.clientes where telefone = p_telefone;
  if found then
    return jsonb_build_object('status', 'ja_existe', 'id', v_ja.id, 'nome', v_ja.nome);
  end if;

  insert into public.clientes (nome, telefone, consentimento_em, cadastro_por)
  values (v_nome, p_telefone, now(), 'recepcao')
  on conflict (telefone) do nothing
  returning id into v_id;

  if v_id is null then
    select id, nome into v_ja from public.clientes where telefone = p_telefone;
    return jsonb_build_object('status', 'ja_existe', 'id', v_ja.id, 'nome', v_ja.nome);
  end if;

  if p_selos > 0 then
    perform public.recepcao_selos_antigos(v_id, p_selos);
  end if;

  return jsonb_build_object('status', 'ok', 'id', v_id, 'selos', p_selos);
end;
$$;

revoke all on function public.recepcao_cadastrar(text, text, int, boolean) from public, anon, authenticated;
grant execute on function public.recepcao_cadastrar(text, text, int, boolean) to authenticated;
