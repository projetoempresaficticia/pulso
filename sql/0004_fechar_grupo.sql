-- Pulso: apagar um grupo é FECHÁ-LO, não destruí-lo.
--
-- CORREÇÃO DE UM ERRO MEU. Na versão anterior, quem criou o grupo apagava-o
-- e as mensagens desapareciam para toda a gente. O Germano apanhou a
-- inconsistência: apagar o grupo e apagar as mensagens dos outros são duas
-- coisas diferentes, e eu tinha-as juntado numa só.
--
-- É a mesma linha que o AeroMail traça e que aqui eu tinha atravessado: uma
-- conversa tem muitos donos, e ninguém apaga as palavras de outra pessoa.
--
-- O QUE APAGAR O GRUPO PASSA A SER:
--
--   • o grupo sai da lista de QUEM O APAGOU, e mais de ninguém;
--   • quem lá está mantém a conversa inteira, com todo o histórico;
--   • fica escrito no fio que o grupo foi fechado, e por quem;
--   • ninguém volta a escrever lá — nem a mudar o nome, nem a acrescentar
--     gente. O que lá está, fica como está.
--
-- Um grupo fechado é um arquivo: lê-se, não se mexe. Quem já não o quiser
-- ver sai dele, como de qualquer outro.
--
-- A ÚNICA VEZ EM QUE A CONVERSA MORRE MESMO continua a ser quando não
-- sobra ninguém — se quem fecha era a última pessoa lá dentro, não fica
-- nenhum histórico para guardar nem ninguém a quem ele pertença.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-06.

alter table public.conversas add column if not exists fechada_em  timestamptz;
alter table public.conversas add column if not exists fechada_por text;

-- Uma mensagem que não é de ninguém: é o próprio sistema a dizer o que
-- aconteceu ao grupo. Vai no fio, no sítio certo da cronologia, porque é
-- aí que faz sentido — não num aviso que se perde.
alter table public.mensagens add column if not exists sistema boolean not null default false;


-- ── fechar ──────────────────────────────────────────────────────────
create or replace function public.msg_grupo_apagar(p_conversa uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu      text := public.fn_minha_cedula();
  v_conv    record;
  v_restam  int;
  v_morreu  boolean := false;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select c.tipo, c.nome, c.fechada_em into v_conv
    from public.conversas c where c.id = p_conversa;
  if v_conv.tipo is null then
    return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.');
  end if;
  if v_conv.tipo <> 'grupo' then
    return jsonb_build_object('ok', false, 'erro',
      'Só se apaga um grupo. Numa conversa a dois, ninguém manda na outra pessoa.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu and papel = 'admin') then
    return jsonb_build_object('ok', false, 'erro', 'Só quem criou o grupo o pode apagar.');
  end if;
  if v_conv.fechada_em is not null then
    return jsonb_build_object('ok', false, 'erro', 'Esse grupo já está fechado.');
  end if;

  -- 1. o aviso fica no fio, antes de eu sair — senão ficava uma conversa
  --    que emudece sem ninguém perceber porquê
  insert into public.mensagens(conversa_id, de_cedula, corpo, sistema)
  values (p_conversa, v_eu,
          public.fn_nome_de(v_eu) || ' fechou o grupo. As mensagens ficam, '
          || 'mas já não é possível escrever aqui.',
          true);

  -- 2. o grupo passa a arquivo, para toda a gente
  update public.conversas
     set fechada_em = now(), fechada_por = v_eu
   where id = p_conversa;

  -- 3. e sai da MINHA lista, e só da minha
  delete from public.conversa_membros
   where conversa_id = p_conversa and cedula = v_eu;

  select count(*) into v_restam
    from public.conversa_membros where conversa_id = p_conversa;

  if v_restam = 0 then
    -- Não sobra ninguém a quem o histórico pertença.
    delete from public.conversas where id = p_conversa;
    v_morreu := true;
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'nome', v_conv.nome,
    'ficaram', v_restam,
    'apagado_de_vez', v_morreu));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível fechar o grupo.');
end;
$$;

revoke execute on function public.msg_grupo_apagar(uuid) from public, anon;
grant execute on function public.msg_grupo_apagar(uuid) to authenticated;


-- ── num grupo fechado, não se escreve ───────────────────────────────
create or replace function public.msg_enviar(p_conversa uuid, p_corpo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu    text := public.fn_minha_cedula();
  v_corpo text := btrim(coalesce(p_corpo, ''));
  v_id    uuid := gen_random_uuid();
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if v_corpo = '' then
    return jsonb_build_object('ok', false, 'erro', 'A mensagem está vazia.');
  end if;
  if length(v_corpo) > 4000 then
    return jsonb_build_object('ok', false, 'erro', 'Mensagem demasiado longa (máximo 4000).');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu) then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;
  -- A verificação vive aqui e não só no ecrã: esconder a caixa de escrever
  -- não impede ninguém de chamar a função por fora.
  if exists (select 1 from public.conversas
              where id = p_conversa and fechada_em is not null) then
    return jsonb_build_object('ok', false, 'erro',
      'Este grupo foi fechado. As mensagens ficam, mas já não se escreve aqui.');
  end if;

  insert into public.mensagens(id, conversa_id, de_cedula, corpo)
  values (v_id, p_conversa, v_eu, v_corpo);

  update public.conversa_membros set ultima_leitura = now()
   where conversa_id = p_conversa and cedula = v_eu;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('id', v_id));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível enviar a mensagem.');
end;
$$;

revoke execute on function public.msg_enviar(uuid, text) from public, anon;
grant execute on function public.msg_enviar(uuid, text) to authenticated;


-- ── nem se mexe no resto ────────────────────────────────────────────
create or replace function public.msg_grupo_membro(p_conversa uuid, p_cedula text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu   text := public.fn_minha_cedula();
  v_alvo text := upper(btrim(coalesce(p_cedula, '')));
  v_conv record;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select c.tipo, c.fechada_em into v_conv from public.conversas c where c.id = p_conversa;
  if v_conv.tipo is null then
    return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.');
  end if;
  if v_conv.tipo <> 'grupo' then
    return jsonb_build_object('ok', false, 'erro',
      'Só se acrescenta gente a um grupo. Crie um grupo novo.');
  end if;
  if v_conv.fechada_em is not null then
    return jsonb_build_object('ok', false, 'erro',
      'Este grupo foi fechado. Não se acrescenta gente a um arquivo.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu and papel = 'admin') then
    return jsonb_build_object('ok', false, 'erro', 'Só quem criou o grupo acrescenta pessoas.');
  end if;
  if not exists (select 1 from public.pessoas
                  where cedula = v_alvo and estado = 'ativa') then
    return jsonb_build_object('ok', false, 'erro', 'Não há ninguém ativo com essa cédula.');
  end if;

  insert into public.conversa_membros(conversa_id, cedula, papel)
  values (p_conversa, v_alvo, 'membro')
  on conflict do nothing;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_alvo, 'nome', public.fn_nome_de(v_alvo)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível acrescentar a pessoa.');
end;
$$;

revoke execute on function public.msg_grupo_membro(uuid, text) from public, anon;
grant execute on function public.msg_grupo_membro(uuid, text) to authenticated;


create or replace function public.msg_grupo_renomear(p_conversa uuid, p_nome text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu   text := public.fn_minha_cedula();
  v_nome text := btrim(coalesce(p_nome, ''));
  v_n    int;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if v_nome = '' then
    return jsonb_build_object('ok', false, 'erro', 'O grupo precisa de um nome.');
  end if;
  if length(v_nome) > 60 then
    return jsonb_build_object('ok', false, 'erro', 'Nome demasiado longo (máximo 60).');
  end if;
  if exists (select 1 from public.conversas
              where id = p_conversa and fechada_em is not null) then
    return jsonb_build_object('ok', false, 'erro',
      'Este grupo foi fechado. O nome com que ficou é o que fica.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu and papel = 'admin') then
    return jsonb_build_object('ok', false, 'erro', 'Só quem criou o grupo muda o nome.');
  end if;

  update public.conversas set nome = v_nome
   where id = p_conversa and tipo = 'grupo';
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'erro', 'Grupo não encontrado.');
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('nome', v_nome));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível mudar o nome.');
end;
$$;

revoke execute on function public.msg_grupo_renomear(uuid, text) from public, anon;
grant execute on function public.msg_grupo_renomear(uuid, text) to authenticated;


-- ── num arquivo, não se apaga o que lá está ─────────────────────────
-- "Para mim" continua a valer: esconder do meu ecrã não mexe no de
-- ninguém. "Para todos" não — isso mudaria um histórico que ficou
-- fechado justamente para deixar de mudar.
create or replace function public.msg_apagar(p_id uuid, p_para_todos boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu text := public.fn_minha_cedula();
  v_m  record;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select g.id, g.conversa_id, g.de_cedula, g.apagada_em, g.sistema into v_m
    from public.mensagens g where g.id = p_id;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Mensagem não encontrada.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = v_m.conversa_id and cedula = v_eu) then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  if coalesce(p_para_todos, false) then
    if v_m.sistema then
      return jsonb_build_object('ok', false, 'erro',
        'Esse aviso é do sistema e não se apaga.');
    end if;
    if v_m.de_cedula <> v_eu then
      return jsonb_build_object('ok', false, 'erro',
        'Só pode apagar para todos aquilo que escreveu.');
    end if;
    if exists (select 1 from public.conversas
                where id = v_m.conversa_id and fechada_em is not null) then
      return jsonb_build_object('ok', false, 'erro',
        'Este grupo foi fechado. O histórico ficou como estava.');
    end if;
    if v_m.apagada_em is null then
      update public.mensagens
         set apagada_em = now(), apagada_por = v_eu, corpo = null
       where id = p_id;
    end if;
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('modo', 'todos'));
  end if;

  insert into public.mensagens_ocultas(mensagem_id, cedula)
  values (p_id, v_eu) on conflict do nothing;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('modo', 'mim'));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível apagar a mensagem.');
end;
$$;

revoke execute on function public.msg_apagar(uuid, boolean) from public, anon;
grant execute on function public.msg_apagar(uuid, boolean) to authenticated;


-- ── as duas leituras passam a dizer que o grupo está fechado ────────
-- `msg_conversas` marca a linha na lista; `msg_historico` marca o fio (para
-- a caixa de escrever sair do ecrã) e distingue os avisos do sistema das
-- mensagens de gente, que se desenham de maneiras diferentes.

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

  select c.id, c.tipo, c.nome, c.fechada_em, c.fechada_por into v_conv
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
               'sistema', g.sistema,
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
    'fechada', v_conv.fechada_em is not null,
    'fechada_por', public.fn_nome_de(v_conv.fechada_por),
    'eu', v_eu,
    'membros', coalesce(v_membros, '[]'::jsonb),
    'linhas', coalesce(v_linhas, '[]'::jsonb)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível abrir a conversa.');
end;
$$;

revoke execute on function public.msg_historico(uuid, int) from public, anon;
grant execute on function public.msg_historico(uuid, int) to authenticated;
