-- Pulso: o canal rápido.
--
-- As quatro tabelas já existiam na base desde a fundação — `conversas`,
-- `conversa_membros`, `mensagens` e `numeros_telefone` — com RLS ligada e
-- ZERO políticas, ou seja, a negar tudo a toda a gente. Faltava abri-las
-- pela medida certa e dar-lhes acções.
--
-- A REGRA CENTRAL, e é uma só: **só vês uma conversa se és membro dela.**
-- É isto que mantém as diretas e os grupos privados, e está escrita duas
-- vezes de propósito — na RLS e outra vez dentro de cada RPC.
--
-- A RECURSÃO QUE ISSO PROVOCA. A política de `conversa_membros` precisa de
-- perguntar a `conversa_membros` quem sou eu naquela conversa. Feito de
-- forma direta, o Postgres entra em recursão infinita e a tabela deixa de
-- responder. Por isso a pergunta passa por `fn_sou_membro`, que é
-- `security definer` e por isso não reentra na política.
--
-- O NÚMERO é o identificador à vista — mais natural do que a cédula para
-- quem está a falar com alguém. Mas por baixo tudo continua ancorado à
-- cédula: o número é uma etiqueta, não uma identidade.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-06.

-- ── o que faltava às tabelas ────────────────────────────────────────
alter table public.conversas drop constraint if exists conversas_tipo_valido;
alter table public.conversas add constraint conversas_tipo_valido
  check (tipo in ('direta', 'grupo'));

-- Uma mensagem apagada para todos deixa marca em vez de desaparecer: num
-- fio de conversa, uma linha que some deixa as respostas seguintes sem
-- sentido nenhum.
alter table public.mensagens
  add column if not exists apagada_em timestamptz;
alter table public.mensagens
  add column if not exists apagada_por text;

-- "Apagar para mim" é de cada um, e por isso não cabe na linha da
-- mensagem: numa conversa de cinco pessoas, cinco pessoas podem esconder
-- coisas diferentes.
create table if not exists public.mensagens_ocultas (
  mensagem_id uuid not null references public.mensagens(id) on delete cascade,
  cedula      text not null,
  ocultada_em timestamptz not null default now(),
  primary key (mensagem_id, cedula)
);
alter table public.mensagens_ocultas enable row level security;

create index if not exists mensagens_conversa
  on public.mensagens(conversa_id, criada_em desc);
create index if not exists conversa_membros_cedula
  on public.conversa_membros(cedula);


-- ── quem é membro de quê ────────────────────────────────────────────
-- `security definer` para quebrar a recursão descrita no topo. É a mesma
-- ponte que a `fn_documento_visivel` do Subsight e a `fn_fisco_visivel`
-- da AT fazem para o Storage.
create or replace function public.fn_sou_membro(p_conversa uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.conversa_membros m
     where m.conversa_id = p_conversa
       and m.cedula = public.fn_minha_cedula());
$$;

revoke execute on function public.fn_sou_membro(uuid) from public, anon;
grant execute on function public.fn_sou_membro(uuid) to authenticated;


-- ── quem vê o quê ───────────────────────────────────────────────────
-- Escrita nenhuma por política: tudo passa pelas RPC, que é onde as regras
-- de negócio vivem (porta única da pp-base).
drop policy if exists "vejo as conversas em que estou" on public.conversas;
create policy "vejo as conversas em que estou"
  on public.conversas for select
  using (public.fn_e_professor() or public.fn_sou_membro(id));

drop policy if exists "vejo quem esta comigo" on public.conversa_membros;
create policy "vejo quem esta comigo"
  on public.conversa_membros for select
  using (public.fn_e_professor() or public.fn_sou_membro(conversa_id));

drop policy if exists "vejo as mensagens das minhas conversas" on public.mensagens;
create policy "vejo as mensagens das minhas conversas"
  on public.mensagens for select
  using (public.fn_e_professor() or public.fn_sou_membro(conversa_id));

drop policy if exists "vejo o que eu proprio escondi" on public.mensagens_ocultas;
create policy "vejo o que eu proprio escondi"
  on public.mensagens_ocultas for select
  using (cedula = public.fn_minha_cedula());

-- A lista telefónica é pública dentro do ecossistema: sem ela ninguém
-- consegue começar uma conversa, porque ninguém sabe números de cor. Não
-- expõe nada que o diretório de entidades já não exponha.
drop policy if exists "a lista telefonica" on public.numeros_telefone;
create policy "a lista telefonica"
  on public.numeros_telefone for select
  using (auth.uid() is not null);


-- ── o meu número ────────────────────────────────────────────────────
-- Idempotente por construção: `fn_gerar_numero` devolve o que já existe.
-- Chamada a cada entrada, dá número a quem ainda não tem sem nunca dar um
-- segundo a quem já tinha.
create or replace function public.msg_meu_numero()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu text := public.fn_minha_cedula();
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_eu,
    'nome', public.fn_nome_de(v_eu),
    'numero', public.fn_gerar_numero(v_eu)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível obter o seu número.');
end;
$$;

revoke execute on function public.msg_meu_numero() from public, anon;
grant execute on function public.msg_meu_numero() to authenticated;


-- ── a quem posso escrever ───────────────────────────────────────────
create or replace function public.msg_contactos(p_procura text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu     text := public.fn_minha_cedula();
  v_linhas jsonb;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select jsonb_agg(x order by x->>'nome')
    into v_linhas
    from (
      select jsonb_build_object(
               'cedula', p.cedula,
               'nome', p.nome,
               'numero', n.numero,
               'empresa', e.nome) as x
        from public.pessoas p
        left join public.numeros_telefone n on n.cedula = p.cedula
        left join public.empresas e on e.id = p.empresa_id
       where p.estado = 'ativa'
         and p.cedula <> v_eu
         and (coalesce(p_procura, '') = ''
              or p.nome ilike '%' || p_procura || '%'
              or p.cedula ilike '%' || p_procura || '%'
              -- procurar pelo número com ou sem espaços
              or replace(coalesce(n.numero, ''), ' ', '')
                   like '%' || replace(coalesce(p_procura, ''), ' ', '') || '%')
       limit 200
    ) t;

  return jsonb_build_object('ok', true, 'dados',
    jsonb_build_object('linhas', coalesce(v_linhas, '[]'::jsonb)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível ler os contactos.');
end;
$$;

revoke execute on function public.msg_contactos(text) from public, anon;
grant execute on function public.msg_contactos(text) to authenticated;


-- ── abrir uma conversa direta ───────────────────────────────────────
-- Idempotente (R8 da pp-base): se já existe conversa a dois com aquela
-- pessoa, devolve-a. Sem isto, dois cliques faziam dois fios paralelos e
-- metade das mensagens ficava no fio errado.
create or replace function public.msg_iniciar_direta(p_destino text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu    text := public.fn_minha_cedula();
  v_alvo  text;
  v_id    uuid;
  v_chave text := replace(btrim(coalesce(p_destino, '')), ' ', '');
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;
  if v_chave = '' then
    return jsonb_build_object('ok', false, 'erro', 'Diga com quem quer falar.');
  end if;

  -- aceita cédula ou número: quem escreve não tem de saber a diferença
  select p.cedula into v_alvo
    from public.pessoas p
    left join public.numeros_telefone n on n.cedula = p.cedula
   where p.estado = 'ativa'
     and (upper(p.cedula) = upper(v_chave) or n.numero = v_chave)
   limit 1;

  if v_alvo is null then
    return jsonb_build_object('ok', false, 'erro',
      'Não há ninguém ativo com essa cédula ou esse número.');
  end if;
  if v_alvo = v_eu then
    return jsonb_build_object('ok', false, 'erro', 'Não pode falar consigo próprio.');
  end if;

  -- uma direta é a conversa de tipo 'direta' onde estamos os dois e mais
  -- ninguém; a contagem é o que impede um grupo de dois de se fazer passar
  -- por ela
  select c.id into v_id
    from public.conversas c
   where c.tipo = 'direta'
     and exists (select 1 from public.conversa_membros m
                  where m.conversa_id = c.id and m.cedula = v_eu)
     and exists (select 1 from public.conversa_membros m
                  where m.conversa_id = c.id and m.cedula = v_alvo)
     and (select count(*) from public.conversa_membros m
           where m.conversa_id = c.id) = 2
   limit 1;

  if v_id is null then
    insert into public.conversas(tipo) values ('direta') returning id into v_id;
    insert into public.conversa_membros(conversa_id, cedula, papel)
    values (v_id, v_eu, 'membro'), (v_id, v_alvo, 'membro');
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'id', v_id, 'outro', v_alvo, 'nome', public.fn_nome_de(v_alvo)));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível abrir a conversa.');
end;
$$;

revoke execute on function public.msg_iniciar_direta(text) from public, anon;
grant execute on function public.msg_iniciar_direta(text) to authenticated;


-- ── criar um grupo ──────────────────────────────────────────────────
create or replace function public.msg_criar_grupo(p_nome text, p_membros text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu    text := public.fn_minha_cedula();
  v_nome  text := btrim(coalesce(p_nome, ''));
  v_id    uuid;
  v_c     text;
  v_n     int := 0;
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
  if p_membros is null or array_length(p_membros, 1) is null then
    return jsonb_build_object('ok', false, 'erro', 'Escolha pelo menos uma pessoa.');
  end if;
  if array_length(p_membros, 1) > 100 then
    return jsonb_build_object('ok', false, 'erro', 'Pessoas a mais para um grupo.');
  end if;

  insert into public.conversas(tipo, nome) values ('grupo', v_nome) returning id into v_id;
  -- quem cria fica admin: alguém tem de poder acrescentar gente depois
  insert into public.conversa_membros(conversa_id, cedula, papel)
  values (v_id, v_eu, 'admin');

  foreach v_c in array p_membros loop
    if v_c is not null and v_c <> v_eu
       and exists (select 1 from public.pessoas p
                    where p.cedula = upper(btrim(v_c)) and p.estado = 'ativa') then
      insert into public.conversa_membros(conversa_id, cedula, papel)
      values (v_id, upper(btrim(v_c)), 'membro')
      on conflict do nothing;
      v_n := v_n + 1;
    end if;
  end loop;

  if v_n = 0 then
    -- um grupo de uma pessoa não é um grupo
    raise exception 'nenhum membro valido';
  end if;

  return jsonb_build_object('ok', true, 'dados',
    jsonb_build_object('id', v_id, 'nome', v_nome, 'membros', v_n + 1));
exception when others then
  return jsonb_build_object('ok', false, 'erro',
    'Não foi possível criar o grupo. Confirme as pessoas escolhidas.');
end;
$$;

revoke execute on function public.msg_criar_grupo(text, text[]) from public, anon;
grant execute on function public.msg_criar_grupo(text, text[]) to authenticated;


-- ── as minhas conversas ─────────────────────────────────────────────
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
          -- a última linha do fio, já sem o que eu escondi
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
        coalesce(u.criada_em, c.criada_em) as ordem
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
        select g.corpo, g.de_cedula, g.criada_em, g.apagada_em
          from public.mensagens g
         where g.conversa_id = c.id
           and not exists (select 1 from public.mensagens_ocultas h
                            where h.mensagem_id = g.id and h.cedula = v_eu)
         order by g.criada_em desc
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


-- ── o fio de uma conversa ───────────────────────────────────────────
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
  -- a regra central, outra vez, agora dentro da RPC
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = p_conversa and cedula = v_eu) then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  select c.id, c.tipo, c.nome into v_conv
    from public.conversas c where c.id = p_conversa;

  select jsonb_agg(x order by (x->>'criada_em'))
    into v_linhas
    from (
      select jsonb_build_object(
               'id', g.id,
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
       order by g.criada_em desc
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


-- ── enviar ──────────────────────────────────────────────────────────
-- O remetente sai SEMPRE de auth.uid() resolvido, nunca de um parâmetro:
-- senão qualquer pessoa escrevia em nome de outra.
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

  insert into public.mensagens(id, conversa_id, de_cedula, corpo)
  values (v_id, p_conversa, v_eu, v_corpo);

  -- quem escreve leu tudo o que estava por ler até aqui
  update public.conversa_membros set ultima_leitura = now()
   where conversa_id = p_conversa and cedula = v_eu;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('id', v_id));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível enviar a mensagem.');
end;
$$;

revoke execute on function public.msg_enviar(uuid, text) from public, anon;
grant execute on function public.msg_enviar(uuid, text) to authenticated;


-- ── marcar como visto ───────────────────────────────────────────────
-- Uma marca por membro, e não uma linha por mensagem e por pessoa: com mil
-- formandos, a segunda hipótese era uma tabela a crescer sem fim para
-- responder a uma pergunta que uma data responde.
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
     and (mm.ultima_leitura is null or g.criada_em > mm.ultima_leitura);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('por_ler', v_por_ler));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível marcar a conversa.');
end;
$$;

revoke execute on function public.msg_marcar_visto(uuid) from public, anon;
grant execute on function public.msg_marcar_visto(uuid) to authenticated;


-- ── apagar ──────────────────────────────────────────────────────────
-- Dois significados diferentes, de propósito:
--   para mim   — some do meu ecrã, e mais ninguém dá por nada;
--   para todos — só quem escreveu, e deixa a marca "mensagem apagada".
-- O segundo não limpa o passado dos outros sem eles verem: uma conversa em
-- que alguém pode fazer desaparecer o que disse não serve para nada.
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

  select g.id, g.conversa_id, g.de_cedula, g.apagada_em into v_m
    from public.mensagens g where g.id = p_id;
  if v_m.id is null then
    return jsonb_build_object('ok', false, 'erro', 'Mensagem não encontrada.');
  end if;
  if not exists (select 1 from public.conversa_membros
                  where conversa_id = v_m.conversa_id and cedula = v_eu) then
    return jsonb_build_object('ok', false, 'erro', 'Essa conversa não é sua.');
  end if;

  if coalesce(p_para_todos, false) then
    if v_m.de_cedula <> v_eu then
      return jsonb_build_object('ok', false, 'erro',
        'Só pode apagar para todos aquilo que escreveu.');
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


-- ── gestão do grupo ─────────────────────────────────────────────────
create or replace function public.msg_grupo_membro(p_conversa uuid, p_cedula text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu   text := public.fn_minha_cedula();
  v_alvo text := upper(btrim(coalesce(p_cedula, '')));
  v_tipo text;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select c.tipo into v_tipo from public.conversas c where c.id = p_conversa;
  if v_tipo is null then
    return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.');
  end if;
  -- Uma direta tem duas pessoas e é isso que a define. Deixar acrescentar
  -- gente transformava-a num grupo sem ninguém decidir isso.
  if v_tipo <> 'grupo' then
    return jsonb_build_object('ok', false, 'erro',
      'Só se acrescenta gente a um grupo. Crie um grupo novo.');
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


create or replace function public.msg_sair(p_conversa uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_eu   text := public.fn_minha_cedula();
  v_tipo text;
  v_n    int;
begin
  if v_eu is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select c.tipo into v_tipo from public.conversas c where c.id = p_conversa;
  if v_tipo <> 'grupo' then
    return jsonb_build_object('ok', false, 'erro', 'Só se sai de um grupo.');
  end if;

  delete from public.conversa_membros
   where conversa_id = p_conversa and cedula = v_eu;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'erro', 'Já não está nesse grupo.');
  end if;

  -- Sair não apaga o que se escreveu: o resto do grupo continua a precisar
  -- do fio inteiro para o que lá está fazer sentido.
  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('saiu', true));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Não foi possível sair do grupo.');
end;
$$;

revoke execute on function public.msg_sair(uuid) from public, anon;
grant execute on function public.msg_sair(uuid) to authenticated;


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
