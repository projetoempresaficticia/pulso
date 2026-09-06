-- Pulso: a ordem de um fio não pode depender da hora.
--
-- O ERRO, apanhado no primeiro teste. A lista de conversas mostrava como
-- "última" a PRIMEIRA de duas mensagens. A causa: `mensagens.criada_em`
-- tem `default now()`, e `now()` em Postgres é o instante de **início da
-- transação**, não do insert. Duas mensagens gravadas na mesma transação
-- ficam com a marca de tempo exatamente igual — e aí o `order by criada_em
-- desc limit 1` desempata ao acaso.
--
-- Numa app de conversa a ordem é a coisa que não pode falhar: um fio fora
-- de ordem é um fio que não se entende. E não há desempate honesto pelo
-- `id`, porque um uuid v4 é aleatório e não guarda ordem nenhuma.
--
-- A CORREÇÃO. Uma sequência, atribuída no momento do insert, que nunca
-- empata. A data continua a servir para mostrar a hora a quem lê; a ordem
-- passa a ser da sequência.
--
-- Podia dizer-se que na prática cada mensagem vem numa transação própria e
-- os microssegundos nunca colidem. É verdade — e mesmo assim o primeiro
-- teste a sério colidiu, porque semear dados faz-se em lote. Uma
-- invariante que depende de "na prática não acontece" não é uma invariante.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-06.

alter table public.mensagens add column if not exists seq bigserial;

create index if not exists mensagens_conversa_seq
  on public.mensagens(conversa_id, seq desc);

-- As duas funções que liam a ordem passam a ler a sequência:
--
--   msg_conversas  — o `left join lateral` que apanha a última linha do
--                    fio passa a `order by g.seq desc`, e a ordem das
--                    conversas na lista passa a ser `coalesce(u.seq, 0)`.
--
--   msg_historico  — apanha as últimas N por `seq desc` e devolve-as por
--                    `seq` crescente, que é a ordem por que se lê um fio.
--                    Passa também a devolver `seq` em cada linha, para o
--                    browser poder inserir uma mensagem nova no sítio
--                    certo sem recarregar tudo.
--
-- O corpo completo das duas está aplicado na base e repetido aqui abaixo
-- para o ficheiro poder ser corrido de raiz.

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
          'membros', (select count(*) from public.conversa_membros m2
                       where m2.conversa_id = c.id),
          'ultima', case when u.apagada_em is not null then null else u.corpo end,
          'ultima_apagada', u.apagada_em is not null,
          'ultima_de', u.de_cedula,
          'ultima_de_nome', public.fn_nome_de(u.de_cedula),
          'ultima_minha', u.de_cedula = v_eu,
          'ultima_em', u.criada_em,
          'por_ler', (select count(*) from public.mensagens g
                       where g.conversa_id = c.id
                         and g.de_cedula <> v_eu
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
        select g.corpo, g.de_cedula, g.criada_em, g.apagada_em, g.seq
          from public.mensagens g
         where g.conversa_id = c.id
           and not exists (select 1 from public.mensagens_ocultas h
                            where h.mensagem_id = g.id and h.cedula = v_eu)
         order by g.seq desc
         limit 1
      ) u on true
      where mm.cedula = v_eu
        and (coalesce(p_procura, '') = ''
             or (c.tipo = 'grupo' and c.nome ilike '%' || p_procura || '%')
             or (c.tipo = 'direta'
                 and (public.fn_nome_de(o.cedula) ilike '%' || p_procura || '%'
                      or o.numero like '%' || replace(p_procura, ' ', '') || '%'))
             or exists (select 1 from public.mensagens g
                         where g.conversa_id = c.id
                           and g.apagada_em is null
                           and g.corpo ilike '%' || p_procura || '%'))
    ) t;

  select count(*)
    into v_por_ler
    from public.conversa_membros mm
    join public.mensagens g on g.conversa_id = mm.conversa_id
   where mm.cedula = v_eu
     and g.de_cedula <> v_eu
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
  v_linhas  jsonb;
  v_membros jsonb;
  v_conv    record;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu) then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  select c.id, c.tipo, c.nome into v_conv
    from public.conversas c where c.id = p_conversa;

  -- as últimas N, mas devolvidas do mais antigo para o mais novo, que é a
  -- ordem por que se lê um fio
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
               'corpo', case when g.apagada_em is null then g.corpo else null end,
               'apagada', g.apagada_em is not null,
               'criada_em', g.criada_em) as x
        from public.mensagens g
       where g.conversa_id = p_conversa
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
    'eu', v_eu,
    'membros', coalesce(v_membros, '[]'::jsonb),
    'linhas', coalesce(v_linhas, '[]'::jsonb)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível abrir a conversa.');
end;
$$;

revoke execute on function public.msg_historico(uuid, int) from public, anon;
grant execute on function public.msg_historico(uuid, int) to authenticated;
