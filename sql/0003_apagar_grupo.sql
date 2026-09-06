-- Pulso: acabar com um grupo.
--
-- UM GRUPO TEM MUITOS DONOS, e isso obriga a separar duas coisas que
-- parecem a mesma:
--
--   SAIR      — é pessoal. Deixo de receber, o grupo some da minha lista,
--               e o que escrevi fica lá para os outros. Já existia.
--   APAGAR    — acaba com o grupo para toda a gente. As mensagens
--               desaparecem, incluindo as que não foram minhas.
--
-- Por isso apagar é só de quem criou o grupo, e a app diz por escrito o que
-- vai acontecer antes de o fazer. É a mesma linha que o AeroMail traça: não
-- se reescreve o passado alheio por acidente — mas quem montou a sala pode
-- desmontá-la, desde que saiba que é isso que está a fazer.
--
-- E O GRUPO QUE FICA VAZIO. Se a última pessoa sai, não fica ninguém a
-- quem a conversa pertença: ela morre sozinha. É a mesma regra do AeroMail
-- — a linha vive enquanto alguém a quiser.
--
-- O GRUPO SEM DONO era um buraco que este pedido destapou. Se quem criou o
-- grupo saísse, ficava um grupo que ninguém podia gerir: sem acrescentar
-- pessoas, sem mudar o nome, sem apagar. Agora, ao sair, o papel de admin
-- passa a quem ficar.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-06.

-- ── que a cascata seja da base, e não da função ─────────────────────
-- `conversa_membros` e `mensagens` apontavam para `conversas` SEM cascata:
-- apagar uma conversa rebentava na chave estrangeira. Podia resolver-se
-- apagando pela ordem certa dentro da função — mas então a garantia
-- passava a depender de quem escreve a próxima função se lembrar da ordem.
-- Assim é a base que garante que não sobram órfãos.
alter table public.conversa_membros
  drop constraint if exists conversa_membros_conversa_id_fkey;
alter table public.conversa_membros
  add constraint conversa_membros_conversa_id_fkey
  foreign key (conversa_id) references public.conversas(id) on delete cascade;

alter table public.mensagens
  drop constraint if exists mensagens_conversa_id_fkey;
alter table public.mensagens
  add constraint mensagens_conversa_id_fkey
  foreign key (conversa_id) references public.conversas(id) on delete cascade;


-- ── apagar o grupo ──────────────────────────────────────────────────
create or replace function public.msg_grupo_apagar(p_conversa uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu    text := public.fn_minha_cedula();
  v_tipo  text;
  v_nome  text;
  v_n     int;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select c.tipo, c.nome into v_tipo, v_nome
    from public.conversas c where c.id = p_conversa;
  if v_tipo is null then
    return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.');
  end if;
  -- Uma direta não se apaga: são duas pessoas e nenhuma manda na outra.
  -- Quem não a quer ver mais apaga as mensagens uma a uma.
  if v_tipo <> 'grupo' then
    return jsonb_build_object('ok', false, 'erro',
      'Só se apaga um grupo. Numa conversa a dois, ninguém manda na outra pessoa.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu and papel = 'admin') then
    return jsonb_build_object('ok', false, 'erro', 'Só quem criou o grupo o pode apagar.');
  end if;

  select count(*) into v_n from public.mensagens where conversa_id = p_conversa;

  -- Uma linha só: a cascata leva os membros, as mensagens, e com elas o
  -- que cada um tinha escondido.
  delete from public.conversas where id = p_conversa;

  return jsonb_build_object('ok', true, 'dados',
    jsonb_build_object('nome', v_nome, 'mensagens', v_n));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível apagar o grupo.');
end;
$$;

revoke execute on function public.msg_grupo_apagar(uuid) from public, anon;
grant execute on function public.msg_grupo_apagar(uuid) to authenticated;


-- ── sair, agora com as duas consequências que faltavam ──────────────
create or replace function public.msg_sair(p_conversa uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu       text := public.fn_minha_cedula();
  v_tipo     text;
  v_era      text;
  v_n        int;
  v_restam   int;
  v_herdeiro text;
  v_morreu   boolean := false;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select c.tipo into v_tipo from public.conversas c where c.id = p_conversa;
  if v_tipo is distinct from 'grupo' then
    return jsonb_build_object('ok', false, 'erro', 'Só se sai de um grupo.');
  end if;

  select papel into v_era from public.conversa_membros
   where conversa_id = p_conversa and cedula = v_eu;

  delete from public.conversa_membros
   where conversa_id = p_conversa and cedula = v_eu;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'erro', 'Já não está nesse grupo.');
  end if;

  select count(*) into v_restam
    from public.conversa_membros where conversa_id = p_conversa;

  if v_restam = 0 then
    -- Ninguém a quem a conversa pertença. Morre sozinha, em vez de ficar
    -- uma sala fechada com as luzes acesas.
    delete from public.conversas where id = p_conversa;
    v_morreu := true;

  elsif v_era = 'admin'
        and not exists (select 1 from public.conversa_membros
                         where conversa_id = p_conversa and papel = 'admin') then
    -- Sem isto ficava um grupo que ninguém podia gerir: sem acrescentar
    -- pessoas, sem mudar o nome, sem apagar. A escolha é por ordem de
    -- cédula — arbitrária, mas igual para toda a gente e sempre a mesma.
    select cedula into v_herdeiro
      from public.conversa_membros
     where conversa_id = p_conversa
     order by cedula
     limit 1;

    update public.conversa_membros set papel = 'admin'
     where conversa_id = p_conversa and cedula = v_herdeiro;
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'saiu', true,
    'grupo_morreu', v_morreu,
    'novo_admin', v_herdeiro));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível sair do grupo.');
end;
$$;

revoke execute on function public.msg_sair(uuid) from public, anon;
grant execute on function public.msg_sair(uuid) to authenticated;
