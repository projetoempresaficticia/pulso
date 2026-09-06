// Pulso — o canal rápido.
//
// Três colunas: as secções, as conversas e o fio aberto. Uma página só,
// porque abrir uma conversa não devia perder o sítio onde se estava.
//
// O TEMPO REAL é subscrito SEM filtro, de propósito. O AeroMail filtra por
// destinatário porque cada mensagem tem um; aqui uma mensagem pertence a
// uma conversa, e as minhas conversas são muitas e mudam. O filtro do
// Realtime só sabe comparar uma coluna a um valor. Como a RLS já só entrega
// as linhas que eu posso ver, subscrever tudo e deixar a política filtrar
// é ao mesmo tempo mais simples e mais seguro do que uma lista de filtros
// que pode ficar desatualizada.

const areaEntrada = document.getElementById('area-entrada');
const areaApp = document.getElementById('area-app');
const elLista = document.getElementById('lista');
const elFio = document.getElementById('fio');
const elCorpo = document.getElementById('corpo');
const elFioVazio = document.getElementById('fio-vazio');
const elFioConteudo = document.getElementById('fio-conteudo');
const msgGeral = document.getElementById('msg-geral');
const campoTexto = document.getElementById('texto');

const estado = {
  eu: null,
  numero: null,
  vista: 'todas',        // todas | grupos | contactos
  procura: '',
  conversas: [],
  contactos: [],
  aberta: null,          // { id, tipo, nome, membros, linhas }
  canal: null,
};

// ══ LISTA ═══════════════════════════════════════════════════════════
function desenharLista() {
  if (estado.vista === 'contactos') return desenharContactos();

  const linhas = estado.vista === 'grupos'
    ? estado.conversas.filter((c) => c.tipo === 'grupo')
    : estado.conversas;

  if (!linhas.length) {
    elLista.innerHTML = `<p class="pu-vazio">${
      estado.procura ? 'Nada corresponde a essa procura.'
      : estado.vista === 'grupos' ? 'Ainda não está em nenhum grupo.'
      : 'Ainda não tem conversas. Carregue no + para começar uma.'}</p>`;
    return;
  }

  elLista.innerHTML = linhas.map((c) => {
    const porLer = Number(c.por_ler) > 0;
    const semente = c.tipo === 'grupo' ? c.id : c.outro;
    // Numa direta o nome é da pessoa; num grupo é do grupo, e a última
    // linha leva o nome de quem a escreveu à frente — senão num grupo de
    // cinco não se sabe quem falou.
    const previa = c.ultima_apagada ? 'Mensagem apagada'
      : c.ultima == null ? 'Sem mensagens'
      : (c.tipo === 'grupo' || c.ultima_minha)
        ? (c.ultima_minha ? 'Você: ' : (c.ultima_de_nome || '') + ': ') + c.ultima
        : c.ultima;
    return `
      <button type="button" class="pu-conversa" data-id="${esc(c.id)}"
              data-por-ler="${porLer}"
              ${estado.aberta && estado.aberta.id === c.id ? 'aria-current="true"' : ''}>
        ${avatar(semente, c.nome)}
        <span style="flex:1;min-width:0">
          <span class="quem">
            <span class="nome">${esc(c.nome || '—')}</span>
            <span class="hora">${esc(quandoCurto(c.ultima_em))}</span>
          </span>
          <span class="ultima">${esc(previa)}</span>
        </span>
        ${porLer ? `<span class="pu-conta">${esc(c.por_ler)}</span>` : ''}
      </button>`;
  }).join('');

  elLista.querySelectorAll('[data-id]').forEach((b) => {
    b.addEventListener('click', () => abrir(b.dataset.id));
  });
}

function desenharContactos() {
  if (!estado.contactos.length) {
    elLista.innerHTML = '<p class="pu-vazio">Ninguém encontrado.</p>';
    return;
  }
  elLista.innerHTML = estado.contactos.map((p) => `
    <button type="button" class="pu-conversa" data-contacto="${esc(p.cedula)}">
      ${avatar(p.cedula, p.nome)}
      <span style="flex:1;min-width:0">
        <span class="quem"><span class="nome">${esc(p.nome)}</span></span>
        <span class="ultima mono">${esc(formatarNumero(p.numero))}${
          p.empresa ? ' · ' + esc(p.empresa) : ''}</span>
      </span>
    </button>`).join('');

  elLista.querySelectorAll('[data-contacto]').forEach((b) => {
    b.addEventListener('click', () => iniciarCom(b.dataset.contacto));
  });
}

async function carregar(manterAberta) {
  mostrarMsg(msgGeral, '');

  if (estado.vista === 'contactos') {
    const r = await api('msg_contactos', { p_procura: estado.procura || null });
    if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
    estado.contactos = r.dados.linhas;
    desenharLista();
    return;
  }

  const r = await api('msg_conversas', { p_procura: estado.procura || null });
  if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
  estado.eu = r.dados.eu;
  estado.numero = r.dados.numero;
  estado.conversas = r.dados.linhas;
  document.getElementById('conta-todas').textContent =
    r.dados.por_ler > 0 ? String(r.dados.por_ler) : '';

  if (!manterAberta) fecharFio();
  desenharLista();
}

// ══ O FIO ═══════════════════════════════════════════════════════════
function fecharFio() {
  estado.aberta = null;
  document.body.dataset.numFio = 'false';
  elFioVazio.hidden = false;
  elFioConteudo.hidden = true;
}

async function abrir(id, semMarcar) {
  const r = await api('msg_historico', { p_conversa: id, p_quantas: 200 });
  if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }

  estado.aberta = r.dados;
  document.body.dataset.numFio = 'true';
  elFioVazio.hidden = true;
  elFioConteudo.hidden = false;

  const d = r.dados;
  const semente = d.tipo === 'grupo' ? d.id : (d.membros.find((m) => !m.sou_eu) || {}).cedula;
  const outro = d.membros.find((m) => !m.sou_eu);
  const nome = d.tipo === 'grupo' ? d.nome : (outro ? outro.nome : '—');

  document.getElementById('fio-avatar').innerHTML = avatar(semente, nome);
  document.getElementById('fio-nome').textContent = nome || '—';
  document.getElementById('fio-sub').textContent = d.tipo === 'grupo'
    ? d.membros.length + ' pessoas'
    : (outro ? formatarNumero(outro.numero) : '');

  desenharFio();
  aoFundo();
  campoTexto.focus();

  if (!semMarcar) {
    const m = await api('msg_marcar_visto', { p_conversa: id });
    if (m.ok) {
      document.getElementById('conta-todas').textContent =
        m.dados.por_ler > 0 ? String(m.dados.por_ler) : '';
      const c = estado.conversas.find((x) => x.id === id);
      if (c) c.por_ler = 0;
      desenharLista();
    }
  }
}

function desenharFio() {
  const d = estado.aberta;
  if (!d) return;
  if (!d.linhas.length) {
    elFio.innerHTML = '<p class="pu-vazio">Ainda não há mensagens. Escreva a primeira.</p>';
    return;
  }

  let anterior = null;
  elFio.innerHTML = d.linhas.map((m) => {
    // O separador de dia só aparece quando o dia muda: repeti-lo em cada
    // linha era ruído, e não o pôr deixava um fio de semanas sem marcos.
    const dia = mesmoDia(anterior, m.criada_em) ? '' :
      `<div class="pu-dia"><span>${esc(diaPorExtenso(m.criada_em))}</span></div>`;
    anterior = m.criada_em;

    if (m.apagada) {
      return dia + `
        <div class="pu-linha ${m.minha ? 'minha' : ''}">
          <span class="pu-balao pu-apagada">Mensagem apagada</span>
        </div>`;
    }

    // Num grupo diz-se quem falou; numa direta só há duas pessoas e o lado
    // da bolha já o diz.
    const autor = (d.tipo === 'grupo' && !m.minha)
      ? `<span class="autor">${esc(m.de_nome)}</span>` : '';

    // Tudo numa linha só: qualquer mudança de linha aqui dentro seria
    // desenhada dentro da bolha, por causa do `pre-wrap` do texto.
    const balao = `<span class="pu-balao ${m.minha ? 'pu-minha' : 'pu-dele'}">`
      + autor
      + `<span class="texto">${esc(m.corpo)}</span>`
      + `<span class="hora">${esc(horaCurta(m.criada_em))}</span>`
      + `<button type="button" class="pu-apagar-balao" data-apagar="${esc(m.id)}"`
      + ` data-minha="${m.minha}" aria-label="Apagar mensagem">`
      + '<span class="pu-icone pu-icone-16 i-lixo" aria-hidden="true"></span>'
      + '</button></span>';

    return dia + `
      <div class="pu-linha ${m.minha ? 'minha' : ''}">
        ${m.minha ? '' : avatar(m.de, m.de_nome, 'pu-avatar-30')}
        ${balao}
      </div>`;
  }).join('');

  elFio.querySelectorAll('[data-apagar]').forEach((b) => {
    b.addEventListener('click', () => apagarMensagem(b.dataset.apagar, b.dataset.minha === 'true'));
  });
}

// Depois de desenhar, o fio tem de ficar no fim: uma conversa abre-se na
// última mensagem, não na primeira.
function aoFundo() {
  elCorpo.scrollTop = elCorpo.scrollHeight;
}

// ══ ENVIAR ══════════════════════════════════════════════════════════
document.getElementById('form-enviar').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const texto = campoTexto.value.trim();
  if (!texto || !estado.aberta) return;

  const btn = document.getElementById('btn-enviar');
  btn.disabled = true;
  const r = await api('msg_enviar', { p_conversa: estado.aberta.id, p_corpo: texto });
  btn.disabled = false;

  if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
  campoTexto.value = '';
  ajustarAltura();
  await abrir(estado.aberta.id, true);
  await carregar(true);
});

// Enter envia, Shift+Enter muda de linha — é o que os dedos já sabem.
campoTexto.addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter' && !ev.shiftKey) {
    ev.preventDefault();
    document.getElementById('form-enviar').requestSubmit();
  }
});

// A caixa cresce com o texto até um limite, e volta a encolher.
function ajustarAltura() {
  campoTexto.style.height = 'auto';
  campoTexto.style.height = Math.min(campoTexto.scrollHeight, 132) + 'px';
}
campoTexto.addEventListener('input', ajustarAltura);

// ══ APAGAR ══════════════════════════════════════════════════════════
async function apagarMensagem(id, minha) {
  let paraTodos = false;

  if (minha) {
    const sim = await perguntar('Apagar para todos?',
      'A mensagem sai da conversa de toda a gente e fica no lugar dela a marca '
      + '"mensagem apagada". Quem já a leu não a desleu.',
      'Apagar para todos');
    if (!sim) return;
    paraTodos = true;
  } else {
    const sim = await perguntar('Apagar da sua conversa?',
      'Some do seu ecrã e mais ninguém dá por nada — quem a escreveu continua '
      + 'a vê-la. Só se apaga para todos aquilo que se escreveu.',
      'Apagar para mim');
    if (!sim) return;
  }

  const r = await api('msg_apagar', { p_id: id, p_para_todos: paraTodos });
  if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
  await abrir(estado.aberta.id, true);
  await carregar(true);
}

// ══ NOVA CONVERSA ═══════════════════════════════════════════════════
const janelaNova = document.getElementById('janela-nova');
const elPessoas = document.getElementById('pessoas');
const msgNova = document.getElementById('msg-nova');
let modoGrupo = false;
let escolhidos = [];
let listaPessoas = [];
// Quando esta janela é aberta a partir de "Acrescentar", escolher alguém
// junta-a ao grupo em vez de abrir uma conversa nova. Guarda-se aqui qual
// é o grupo; a null, a janela está no seu papel normal.
let juntarAoGrupo = null;

function trocarModo(grupo) {
  modoGrupo = grupo;
  escolhidos = [];
  document.getElementById('aba-pessoa').setAttribute('aria-pressed', String(!grupo));
  document.getElementById('aba-grupo').setAttribute('aria-pressed', String(grupo));
  document.getElementById('campo-nome-grupo').hidden = !grupo;
  document.getElementById('btn-criar-grupo').hidden = !grupo;
  document.getElementById('titulo-nova').textContent =
    grupo ? 'Novo grupo' : 'Nova conversa';
  mostrarMsg(msgNova, '');
  desenharPessoas();
}

document.getElementById('aba-pessoa').addEventListener('click', () => trocarModo(false));
document.getElementById('aba-grupo').addEventListener('click', () => trocarModo(true));

function desenharPessoas() {
  if (!listaPessoas.length) {
    elPessoas.innerHTML = '<p class="pu-vazio">Ninguém encontrado.</p>';
    return;
  }
  elPessoas.innerHTML = listaPessoas.map((p) => {
    const dentro = escolhidos.indexOf(p.cedula) >= 0;
    return `
      <button type="button" class="pu-pessoa" data-cedula="${esc(p.cedula)}"
              ${modoGrupo ? `aria-pressed="${dentro}"` : ''}>
        ${avatar(p.cedula, p.nome, 'pu-avatar-30')}
        <span style="flex:1;min-width:0">
          <span class="nome">${esc(p.nome)}</span>
          <span class="sub mono">${esc(formatarNumero(p.numero))}${
            p.empresa ? ' · ' + esc(p.empresa) : ''}</span>
        </span>
        ${modoGrupo && dentro ? '<span class="marca-escolhido">escolhido</span>' : ''}
      </button>`;
  }).join('');

  elPessoas.querySelectorAll('[data-cedula]').forEach((b) => {
    b.addEventListener('click', () => {
      const c = b.dataset.cedula;
      if (!modoGrupo) { janelaNova.close(); iniciarCom(c); return; }
      const i = escolhidos.indexOf(c);
      if (i >= 0) escolhidos.splice(i, 1); else escolhidos.push(c);
      document.getElementById('btn-criar-grupo').disabled = escolhidos.length === 0;
      desenharPessoas();
    });
  });
}

async function carregarPessoas(procura) {
  const r = await api('msg_contactos', { p_procura: procura || null });
  if (!r.ok) { mostrarMsg(msgNova, r.erro, 'erro'); return; }
  listaPessoas = r.dados.linhas;
  desenharPessoas();
}

document.getElementById('btn-nova').addEventListener('click', async () => {
  trocarModo(false);
  document.getElementById('nome-grupo').value = '';
  document.getElementById('procura-pessoas').value = '';
  abrirJanela('janela-nova');
  await carregarPessoas('');
});

let temporizadorPessoas = null;
document.getElementById('procura-pessoas').addEventListener('input', (ev) => {
  clearTimeout(temporizadorPessoas);
  temporizadorPessoas = setTimeout(() => carregarPessoas(ev.target.value.trim()), 250);
});

async function iniciarCom(cedulaOuNumero) {
  if (juntarAoGrupo) {
    const grupo = juntarAoGrupo;
    juntarAoGrupo = null;
    const j = await api('msg_grupo_membro',
      { p_conversa: grupo, p_cedula: cedulaOuNumero });
    if (!j.ok) { mostrarMsg(msgGeral, j.erro, 'erro'); return; }
    await carregar(true);
    await abrir(grupo, true);
    return;
  }

  const r = await api('msg_iniciar_direta', { p_destino: cedulaOuNumero });
  if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
  trocarVista('todas');
  await carregar(true);
  await abrir(r.dados.id);
}

document.getElementById('btn-criar-grupo').addEventListener('click', async () => {
  const nome = document.getElementById('nome-grupo').value.trim();
  if (!nome) { mostrarMsg(msgNova, 'O grupo precisa de um nome.', 'erro'); return; }
  if (!escolhidos.length) { mostrarMsg(msgNova, 'Escolha pelo menos uma pessoa.', 'erro'); return; }

  const r = await api('msg_criar_grupo', { p_nome: nome, p_membros: escolhidos });
  if (!r.ok) { mostrarMsg(msgNova, r.erro, 'erro'); return; }
  janelaNova.close();
  trocarVista('todas');
  await carregar(true);
  await abrir(r.dados.id);
});

// ══ DETALHES ════════════════════════════════════════════════════════
document.getElementById('btn-detalhes').addEventListener('click', () => {
  const d = estado.aberta;
  if (!d) return;
  const souAdmin = !!d.membros.find((m) => m.sou_eu && m.papel === 'admin');

  document.getElementById('titulo-detalhes').textContent =
    d.tipo === 'grupo' ? 'Grupo' : 'Contacto';

  document.getElementById('detalhes-corpo').innerHTML = `
    ${d.tipo === 'grupo' && souAdmin ? `
      <div class="pu-campo">
        <label for="novo-nome-grupo">Nome do grupo</label>
        <input id="novo-nome-grupo" maxlength="60" value="${esc(d.nome || '')}" />
      </div>` : ''}
    <h3 style="margin-bottom:12px">
      ${d.tipo === 'grupo' ? d.membros.length + ' pessoas' : 'Quem está nesta conversa'}
    </h3>
    <div class="pu-pessoas">
      ${d.membros.map((m) => `
        <div class="pu-pessoa" style="cursor:default">
          ${avatar(m.cedula, m.nome, 'pu-avatar-30')}
          <span style="flex:1;min-width:0">
            <span class="nome">${esc(m.nome)}${m.sou_eu ? ' (você)' : ''}</span>
            <span class="sub mono">${esc(formatarNumero(m.numero))}</span>
          </span>
          ${m.papel === 'admin'
            ? '<span class="pu-selo pu-selo-grupo">criou o grupo</span>' : ''}
        </div>`).join('')}
    </div>
    <p class="pu-msg" id="msg-detalhes"></p>`;

  // Sair é pessoal; apagar acaba com o grupo para toda a gente. São coisas
  // diferentes e ficam separadas — apagar só aparece a quem o criou.
  document.getElementById('detalhes-pe').innerHTML = d.tipo === 'grupo'
    ? `${souAdmin ? `
         <button type="button" class="pu-botao pu-botao-linha" id="btn-juntar">
           <span class="pu-icone i-contactos" aria-hidden="true"></span>Acrescentar
         </button>
         <button type="button" class="pu-botao" id="btn-guardar-nome">Guardar nome</button>` : ''}
       <button type="button" class="pu-botao pu-botao-linha" id="btn-sair-grupo">
         <span class="pu-icone i-sair" aria-hidden="true"></span>Sair do grupo
       </button>
       ${souAdmin ? `
         <button type="button" class="pu-botao pu-botao-linha" id="btn-apagar-grupo">
           <span class="pu-icone i-lixo" aria-hidden="true"></span>Apagar grupo
         </button>` : ''}`
    : `<button type="button" class="pu-botao pu-botao-linha"
               data-fechar="janela-detalhes">Fechar</button>`;

  ligarDetalhes();
  abrirJanela('janela-detalhes');
});

function ligarDetalhes() {
  const janela = document.getElementById('janela-detalhes');
  janela.querySelectorAll('[data-fechar]').forEach((b) => {
    b.addEventListener('click', () => janela.close());
  });

  const guardar = document.getElementById('btn-guardar-nome');
  if (guardar) guardar.addEventListener('click', async () => {
    const nome = document.getElementById('novo-nome-grupo').value.trim();
    const r = await api('msg_grupo_renomear',
      { p_conversa: estado.aberta.id, p_nome: nome });
    if (!r.ok) { mostrarMsg(document.getElementById('msg-detalhes'), r.erro, 'erro'); return; }
    janela.close();
    await carregar(true);
    await abrir(estado.aberta.id, true);
  });

  const juntar = document.getElementById('btn-juntar');
  if (juntar) juntar.addEventListener('click', async () => {
    janela.close();
    juntarAoGrupo = estado.aberta.id;
    trocarModo(false);
    document.getElementById('titulo-nova').textContent = 'Acrescentar ao grupo';
    document.getElementById('procura-pessoas').value = '';
    abrirJanela('janela-nova');
    await carregarPessoas('');
  });

  const sair = document.getElementById('btn-sair-grupo');
  if (sair) sair.addEventListener('click', async () => {
    const id = estado.aberta.id;
    const sozinho = estado.aberta.membros.length === 1;
    janela.close();

    const sim = await perguntar('Sair do grupo?',
      sozinho
        ? 'É a última pessoa cá dentro. Ao sair, o grupo acaba e as mensagens '
          + 'desaparecem — não fica ninguém a quem a conversa pertença.'
        : 'Deixa de receber as mensagens. O que já escreveu fica — o resto do '
          + 'grupo precisa do fio inteiro para o que lá está fazer sentido.',
      'Sair do grupo');
    if (!sim) return;

    const r = await api('msg_sair', { p_conversa: id });
    if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
    fecharFio();
    await carregar(false);
    if (r.dados.grupo_morreu) {
      mostrarMsg(msgGeral, 'Saiu, e como era a última pessoa o grupo acabou.', 'aviso');
    } else if (r.dados.novo_admin) {
      // Quem fica tem de saber que passou a poder gerir o grupo, senão
      // descobre-o por acaso semanas depois.
      mostrarMsg(msgGeral, 'Saiu. A gestão do grupo passou a quem lá ficou.', 'aviso');
    }
  });

  const apagar = document.getElementById('btn-apagar-grupo');
  if (apagar) apagar.addEventListener('click', async () => {
    const id = estado.aberta.id;
    const nome = estado.aberta.nome;
    const quantos = estado.aberta.membros.length;
    janela.close();

    // O texto diz exatamente o que se perde. Um grupo tem muitos donos: a
    // pessoa tem de perceber que não está só a arrumar a sua caixa.
    const sim = await perguntar(`Apagar o grupo "${nome}"?`,
      `O grupo acaba para as ${quantos} pessoas que lá estão, e as mensagens `
      + 'desaparecem — incluindo as que não foram suas. Isto não tem volta. '
      + 'Se só quer deixar de o receber, use "Sair do grupo".',
      'Apagar o grupo');
    if (!sim) return;

    const r = await api('msg_grupo_apagar', { p_conversa: id });
    if (!r.ok) { mostrarMsg(msgGeral, r.erro, 'erro'); return; }
    fecharFio();
    await carregar(false);
    mostrarMsg(msgGeral,
      `Grupo "${r.dados.nome}" apagado, com ${r.dados.mensagens} mensagem(ns).`, 'aviso');
  });
}

// Fechar a janela sem escolher ninguém desfaz o modo "acrescentar":
// senão a próxima pessoa escolhida ia parar a um grupo que já ninguém
// tinha em mente.
janelaNova.addEventListener('close', () => { juntarAoGrupo = null; });

// ══ VISTAS, PROCURA ═════════════════════════════════════════════════
function trocarVista(vista) {
  estado.vista = vista;
  document.querySelectorAll('.pu-nav[data-vista]').forEach((b) => {
    b.setAttribute('aria-current', String(b.dataset.vista === vista));
  });
  const titulos = { todas: 'Conversas', grupos: 'Grupos', contactos: 'Contactos' };
  document.getElementById('titulo-vista').textContent = titulos[vista] || 'Conversas';
  document.getElementById('procura').placeholder = vista === 'contactos'
    ? 'Procurar nome, cédula ou número'
    : 'Procurar conversa, nome ou número';
  carregar(true);
}

document.querySelectorAll('.pu-nav[data-vista]').forEach((b) => {
  b.addEventListener('click', () => trocarVista(b.dataset.vista));
});

let temporizador = null;
document.getElementById('procura').addEventListener('input', (ev) => {
  clearTimeout(temporizador);
  temporizador = setTimeout(() => {
    estado.procura = ev.target.value.trim();
    carregar(true);
  }, 250);
});

document.getElementById('btn-voltar').addEventListener('click', fecharFio);

// ══ TEMPO REAL ══════════════════════════════════════════════════════
async function ligarRealtime() {
  if (estado.canal) sb.removeChannel(estado.canal);

  // O Realtime só aplica a RLS se lhe passarmos o token da sessão. Sem
  // isto o canal ligava-se como anónimo e a política — que pergunta de que
  // conversas sou membro — não deixava passar nada.
  const { data } = await sb.auth.getSession();
  if (data.session) sb.realtime.setAuth(data.session.access_token);

  estado.canal = sb.channel('pulso-' + estado.eu)
    .on('postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'mensagens' }, aoMexer)
    .on('postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'mensagens' }, aoMexer)
    .subscribe();
}

async function aoMexer(payload) {
  const linha = payload.new || {};
  const aberta = estado.aberta;

  // Recarrega-se pela RPC em vez de enfiar a linha crua na lista: a linha
  // não traz o nome de quem escreveu nem a contagem por ler, que a função
  // calcula. E se a mensagem é da conversa aberta, ela fica marcada como
  // vista — porque está mesmo à frente de quem a recebeu.
  if (aberta && linha.conversa_id === aberta.id) {
    const perto = elCorpo.scrollHeight - elCorpo.scrollTop - elCorpo.clientHeight < 120;
    await abrir(aberta.id);
    if (perto) aoFundo();
  }
  await carregar(true);
}

// ══ ARRANQUE ════════════════════════════════════════════════════════
async function entrar() {
  areaEntrada.hidden = true;
  areaApp.hidden = false;

  const pessoa = await quemSou();
  if (!pessoa) {
    elLista.innerHTML = '<p class="pu-vazio">Não tem ficha na Carteirinha.</p>';
    document.getElementById('nome-quem').textContent = 'Sem ficha';
    return;
  }

  // Dá número a quem ainda não tem. É idempotente: quem já tinha, mantém.
  const n = await api('msg_meu_numero', {});
  document.getElementById('nome-quem').textContent = pessoa.nome;
  document.getElementById('numero-quem').textContent =
    n.ok ? formatarNumero(n.dados.numero) : '';
  estado.eu = pessoa.cedula;

  fecharFio();
  await carregar(false);
  await ligarRealtime();
}

document.getElementById('btn-sair').addEventListener('click', async () => {
  if (estado.canal) sb.removeChannel(estado.canal);
  await sb.auth.signOut();
  window.location.reload();
});

(async function arrancar() {
  ligarVerSenha();
  ligarFormularioLogin(entrar);
  const { data } = await sb.auth.getSession();
  if (data.session) await entrar();
  else areaEntrada.hidden = false;
})();
