-- Pulso: apagar uma conversa.
--
-- Vale o princípio que o Germano fixou ao corrigir o apagar do grupo:
-- **ninguém apaga as palavras de outra pessoa.** Numa conversa a dois isso
-- é ainda mais claro — não há dono, há dois.
--
-- Por isso apagar a conversa é apagar A MINHA CÓPIA:
--
--   • a conversa sai da minha lista, com o histórico dela;
--   • do outro lado não muda absolutamente nada;
--   • se essa pessoa voltar a escrever, a conversa reaparece — mas só com
--     o que for novo. O que apaguei, apaguei.
--
-- COMO, sem uma linha por mensagem e por pessoa. Guarda-se uma marca de
-- corte em `conversa_membros`: a última mensagem que existia quando
-- apaguei. Tudo o que vem antes dessa marca deixa de existir para mim;
-- tudo o que vier depois aparece. Uma coluna resolve o esconder e o
-- reaparecer ao mesmo tempo, e não cresce com o número de mensagens.
--
-- A marca é a SEQUÊNCIA e não a data, pela mesma razão da migração 0002:
-- `now()` é o início da transação e empata; a sequência nunca.
--
-- E O GRUPO. Continua a ter "Sair", que é o verbo certo lá — sair é
-- deixar de pertencer. Esta função aceita as duas, porque limpar a minha
-- cópia sem sair é uma coisa que faz sentido num grupo com muito ruído,
-- mas por agora só a conversa a dois a oferece no ecrã.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-06.

alter table public.conversa_membros
  add column if not exists limpa_ate bigint;


create or replace function public.msg_conversa_apagar(p_conversa uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu     text := public.fn_minha_cedula();
  v_ultima bigint;
  v_n      int;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu) then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  select max(seq) into v_ultima
    from public.mensagens where conversa_id = p_conversa;

  -- Sem mensagens não há nada a apagar, e a marca ficaria a zero — o que
  -- não é o mesmo que "nada para mostrar".
  if v_ultima is null then
    return jsonb_build_object('ok', true, 'dados',
      jsonb_build_object('apagadas', 0));
  end if;

  select count(*) into v_n
    from public.mensagens g
    join public.conversa_membros mm
      on mm.conversa_id = g.conversa_id and mm.cedula = v_eu
   where g.conversa_id = p_conversa
     and (mm.limpa_ate is null or g.seq > mm.limpa_ate);

  update public.conversa_membros
     set limpa_ate = v_ultima,
         ultima_leitura = now()
   where conversa_id = p_conversa and cedula = v_eu;

  return jsonb_build_object('ok', true, 'dados',
    jsonb_build_object('apagadas', v_n));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível apagar a conversa.');
end;
$$;

revoke execute on function public.msg_conversa_apagar(uuid) from public, anon;
grant execute on function public.msg_conversa_apagar(uuid) to authenticated;


-- ── as leituras respeitam a marca de corte ──────────────────────────
create or replace function public.msg_conversas(p_procura text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu      text := public.fn_minha_cedula();
  v_linhas  jsonb;
  v_por_ler int;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select jsonb_agg(x order by ordem desc nulls last)
    into v_linhas
    from (
      select
        jsonb_build_object(
          'id', c.id,
          'tipo', c.tipo,
          'nome', case when c.tipo = 'grupo' then c.nome
                       else coalesce(public.fn_nome_de(o.cedula), o.cedula) end,
          'outro', o.cedula,
          'numero', o.numero,
          'sou_admin', mm.papel = 'admin',
          'fechada', c.fechada_em is not null,
          'fechada_por', public.fn_nome_de(c.fechada_por),
          'membros', (select count(*) from public.conversa_membros m2
                       where m2.conversa_id = c.id),
          'ultima', case when u.apagada_em is not null then null else u.corpo end,
          'ultima_apagada', u.apagada_em is not null,
          'ultima_sistema', coalesce(u.sistema, false),
          'ultima_de', u.de_cedula,
          'ultima_de_nome', public.fn_nome_de(u.de_cedula),
          'ultima_minha', u.de_cedula = v_eu,
          'ultima_em', u.criada_em,
          'por_ler', (select count(*) from public.mensagens g
                       where g.conversa_id = c.id
                         and g.de_cedula <> v_eu
                         and (mm.limpa_ate is null or g.seq > mm.limpa_ate)
                         and (mm.ultima_leitura is null
                              or g.criada_em > mm.ultima_leitura))
        ) as x,
        coalesce(u.seq, 0) as ordem
      from public.conversa_membros mm
      join public.conversas c on c.id = mm.conversa_id
      left join lateral (
        select m3.cedula, n.numero
          from public.conversa_membros m3
          left join public.numeros_telefone n on n.cedula = m3.cedula
         where m3.conversa_id = c.id and m3.cedula <> v_eu
         limit 1
      ) o on c.tipo = 'direta'
      left join lateral (
        select g.corpo, g.de_cedula, g.criada_em, g.apagada_em, g.seq, g.sistema
          from public.mensagens g
         where g.conversa_id = c.id
           and (mm.limpa_ate is null or g.seq > mm.limpa_ate)
           and not exists (select 1 from public.mensagens_ocultas h
                            where h.mensagem_id = g.id and h.cedula = v_eu)
         order by g.seq desc
         limit 1
      ) u on true
      where mm.cedula = v_eu
        -- Apagada e sem nada de novo: fora da lista. Volta sozinha assim
        -- que a outra pessoa escrever, porque aí já há algo depois do corte.
        and (mm.limpa_ate is null or u.seq is not null)
        and (coalesce(p_procura, '') = ''
             or (c.tipo = 'grupo' and c.nome ilike '%' || p_procura || '%')
             or (c.tipo = 'direta'
                 and (public.fn_nome_de(o.cedula) ilike '%' || p_procura || '%'
                      or o.numero like '%' || replace(p_procura, ' ', '') || '%'))
             or exists (select 1 from public.mensagens g
                         where g.conversa_id = c.id
                           and (mm.limpa_ate is null or g.seq > mm.limpa_ate)
                           and g.apagada_em is null
                           and g.corpo ilike '%' || p_procura || '%'))
    ) t;

  select count(*)
    into v_por_ler
    from public.conversa_membros mm
    join public.mensagens g on g.conversa_id = mm.conversa_id
   where mm.cedula = v_eu
     and g.de_cedula <> v_eu
     and (mm.limpa_ate is null or g.seq > mm.limpa_ate)
     and (mm.ultima_leitura is null or g.criada_em > mm.ultima_leitura);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'eu', v_eu,
    'numero', (select numero from public.numeros_telefone where cedula = v_eu),
    'por_ler', v_por_ler,
    'linhas', coalesce(v_linhas, '[]'::jsonb)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível abrir as conversas.');
end;
$$;

revoke execute on function public.msg_conversas(text) from public, anon;
grant execute on function public.msg_conversas(text) to authenticated;


create or replace function public.msg_historico(p_conversa uuid, p_quantas int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu      text := public.fn_minha_cedula();
  v_quantas int := least(greatest(coalesce(p_quantas, 200), 1), 500);
  v_corte   bigint;
  v_linhas  jsonb;
  v_membros jsonb;
  v_conv    record;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select limpa_ate into v_corte
    from public.conversa_membros
   where conversa_id = p_conversa and cedula = v_eu;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  select c.id, c.tipo, c.nome, c.fechada_em, c.fechada_por into v_conv
    from public.conversas c where c.id = p_conversa;

  select jsonb_agg(x order by seq)
    into v_linhas
    from (
      select g.seq,
             jsonb_build_object(
               'id', g.id,
               'seq', g.seq,
               'de', g.de_cedula,
               'de_nome', public.fn_nome_de(g.de_cedula),
               'minha', g.de_cedula = v_eu,
               'sistema', g.sistema,
               'corpo', case when g.apagada_em is null then g.corpo else null end,
               'apagada', g.apagada_em is not null,
               'criada_em', g.criada_em) as x
        from public.mensagens g
       where g.conversa_id = p_conversa
         and (v_corte is null or g.seq > v_corte)
         and not exists (select 1 from public.mensagens_ocultas h
                          where h.mensagem_id = g.id and h.cedula = v_eu)
       order by g.seq desc
       limit v_quantas
    ) t;

  select jsonb_agg(jsonb_build_object(
           'cedula', m.cedula,
           'nome', public.fn_nome_de(m.cedula),
           'numero', n.numero,
           'papel', m.papel,
           'sou_eu', m.cedula = v_eu)
         order by public.fn_nome_de(m.cedula))
    into v_membros
    from public.conversa_membros m
    left join public.numeros_telefone n on n.cedula = m.cedula
   where m.conversa_id = p_conversa;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'id', v_conv.id,
    'tipo', v_conv.tipo,
    'nome', v_conv.nome,
    'fechada', v_conv.fechada_em is not null,
    'fechada_por', public.fn_nome_de(v_conv.fechada_por),
    'limpa', v_corte is not null,
    'eu', v_eu,
    'membros', coalesce(v_membros, '[]'::jsonb),
    'linhas', coalesce(v_linhas, '[]'::jsonb)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível abrir a conversa.');
end;
$$;

revoke execute on function public.msg_historico(uuid, int) from public, anon;
grant execute on function public.msg_historico(uuid, int) to authenticated;


create or replace function public.msg_marcar_visto(p_conversa uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu      text := public.fn_minha_cedula();
  v_n       int;
  v_por_ler int;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  update public.conversa_membros set ultima_leitura = now()
   where conversa_id = p_conversa and cedula = v_eu;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  select count(*)
    into v_por_ler
    from public.conversa_membros mm
    join public.mensagens g on g.conversa_id = mm.conversa_id
   where mm.cedula = v_eu
     and g.de_cedula <> v_eu
     and (mm.limpa_ate is null or g.seq > mm.limpa_ate)
     and (mm.ultima_leitura is null or g.criada_em > mm.ultima_leitura);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('por_ler', v_por_ler));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível marcar a conversa.');
end;
$$;

revoke execute on function public.msg_marcar_visto(uuid) from public, anon;
grant execute on function public.msg_marcar_visto(uuid) to authenticated;
