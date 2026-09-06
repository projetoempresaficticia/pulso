// Pulso — utilitários da biblioteca deste app.
// O cliente Supabase (`sb`) e o `api()` vêm do comum.js da pp-base.

// Escapar o que vem da base antes de o pôr em innerHTML. Aqui conta mais
// do que em quase todo o lado: o corpo de uma mensagem é texto que outra
// pessoa escreveu de propósito.
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function mostrarMsg(el, texto, tipo) {
  if (!el) return;
  el.textContent = texto || '';
  el.className = 'pu-msg' + (tipo ? ' pu-msg-' + tipo : '');
}

// ── o número ───────────────────────────────────────────────────────
// Guardado como nove dígitos seguidos; mostrado aos pares de três, que é
// como se lê um telemóvel em Portugal. A formatação é do ecrã, nunca da
// base — nunca se faz contas com um número de telefone.
function formatarNumero(n) {
  const d = String(n || '').replace(/\D/g, '');
  if (d.length !== 9) return d || '—';
  return d.slice(0, 3) + ' ' + d.slice(3, 6) + ' ' + d.slice(6);
}

// ── tempo ──────────────────────────────────────────────────────────
function horaCurta(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString('pt-PT',
    { hour: '2-digit', minute: '2-digit' });
}

// Na lista de conversas não cabe a data toda. Hoje mostra-se a hora — é o
// que distingue duas de hoje; noutro dia mostra-se o dia.
function quandoCurto(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const agora = new Date();
  if (d.toDateString() === agora.toDateString()) return horaCurta(iso);

  const ontem = new Date(agora);
  ontem.setDate(agora.getDate() - 1);
  if (d.toDateString() === ontem.toDateString()) return 'ontem';

  const mesmoAno = d.getFullYear() === agora.getFullYear();
  return d.toLocaleDateString('pt-PT', mesmoAno
    ? { day: '2-digit', month: 'short' }
    : { day: '2-digit', month: '2-digit', year: '2-digit' });
}

// O separador que se põe entre dias, dentro do fio.
function diaPorExtenso(iso) {
  const d = new Date(iso);
  const agora = new Date();
  if (d.toDateString() === agora.toDateString()) return 'Hoje';
  const ontem = new Date(agora);
  ontem.setDate(agora.getDate() - 1);
  if (d.toDateString() === ontem.toDateString()) return 'Ontem';
  return d.toLocaleDateString('pt-PT',
    { weekday: 'long', day: '2-digit', month: 'long' });
}

function mesmoDia(a, b) {
  if (!a || !b) return false;
  return new Date(a).toDateString() === new Date(b).toDateString();
}

// ── avatar ─────────────────────────────────────────────────────────
// A cédula é única e nunca muda, por isso serve de semente: a mesma pessoa
// tem sempre a mesma cor, em qualquer ecrã e em qualquer sessão. Não é
// decoração — é o que deixa reconhecer alguém antes de ler o nome.
//
// Todas as cores têm contraste suficiente com o branco por cima (>= 4,5:1),
// e todas pertencem à família índigo/ardósia do kit. Uma cor clara aqui
// obrigaria a texto escuro nalgumas e claro noutras.
const PU_CORES = [
  '#1F2747', '#38446A', '#4A3A6B', '#2A5D74',
  '#6B3B5C', '#2A7259', '#5B4A2A', '#3F4C7A',
];

function corDaCedula(cedula) {
  const s = String(cedula || '');
  let n = 0;
  for (let i = 0; i < s.length; i += 1) n = (n * 31 + s.charCodeAt(i)) % 100000;
  return PU_CORES[n % PU_CORES.length];
}

function iniciaisDe(nome) {
  const partes = String(nome || '?').trim().split(/\s+/).filter(Boolean);
  if (!partes.length) return '?';
  if (partes.length === 1) return partes[0].slice(0, 2).toUpperCase();
  return (partes[0][0] + partes[partes.length - 1][0]).toUpperCase();
}

function avatar(cedula, nome, classe) {
  return `<span class="pu-avatar ${classe || ''}" aria-hidden="true"
    style="background:${corDaCedula(cedula)}">${esc(iniciaisDe(nome))}</span>`;
}

// ── quem sou ───────────────────────────────────────────────────────
async function quemSou() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return null;
  const { data: pessoa } = await sb
    .from('pessoas').select('cedula, nome, papel, empresa_id')
    .eq('id', data.session.user.id).single();
  return pessoa || null;
}

// ── versão do site nos links internos ──────────────────────────────
// O GitHub Pages guarda o HTML dez minutos e não deixa mudar isso. Um link
// para o endereço nu vai buscar a cópia velha dessa página, que por sua vez
// nomeia o JS e o CSS velhos — e a correção parece não pegar.
function versaoDoSite() {
  const m = document.querySelector('meta[name="pu-versao"]');
  return (m && m.content) ? m.content : '';
}

function comVersao(href) {
  const v = versaoDoSite();
  if (!v || /^https?:/.test(href)) return href;
  return href + (href.includes('?') ? '&' : '?') + 'v=' + encodeURIComponent(v);
}

function versionarLinks() {
  document.querySelectorAll('a[href$=".html"]').forEach((a) => {
    const h = a.getAttribute('href');
    if (!h || /^https?:/.test(h) || h.includes('v=')) return;
    a.setAttribute('href', comVersao(h));
  });
}
document.addEventListener('DOMContentLoaded', versionarLinks);

// ── entrada ────────────────────────────────────────────────────────
function ligarVerSenha() {
  const btn = document.getElementById('btn-ver-senha');
  const campo = document.getElementById('senha');
  if (!btn || !campo) return;
  btn.addEventListener('click', () => {
    const aMostrar = campo.type === 'password';
    campo.type = aMostrar ? 'text' : 'password';
    btn.textContent = aMostrar ? 'Esconder' : 'Mostrar';
    btn.setAttribute('aria-pressed', String(aMostrar));
    campo.focus();
  });
}

function ligarFormularioLogin(aoEntrar) {
  const form = document.getElementById('form-login');
  if (!form) return;
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = document.getElementById('msg-login');
    const btn = form.querySelector('button[type="submit"]');
    if (btn) btn.disabled = true;
    mostrarMsg(msg, 'A entrar…');
    const { error } = await sb.auth.signInWithPassword({
      email: document.getElementById('email').value,
      password: document.getElementById('senha').value,
    });
    if (btn) btn.disabled = false;
    if (error) {
      mostrarMsg(msg, 'Email ou senha errados.', 'erro');
      return;
    }
    mostrarMsg(msg, '');
    await aoEntrar();
  });
}

// ── janelas ────────────────────────────────────────────────────────
// <dialog> nativo: já traz a armadilha de foco, o Escape e o fundo inerte.
function abrirJanela(id) {
  const d = document.getElementById(id);
  if (d && !d.open) d.showModal();
  return d;
}

function ligarFechos() {
  document.querySelectorAll('[data-fechar]').forEach((b) => {
    b.addEventListener('click', () => {
      const d = document.getElementById(b.dataset.fechar);
      if (d) d.close();
    });
  });
}
document.addEventListener('DOMContentLoaded', ligarFechos);

// Uma pergunta de sim ou não, com a janela do app. O confirm() do browser,
// a seguir a um ecrã desenhado, lê-se como um erro.
function perguntar(titulo, texto, rotuloSim) {
  return new Promise((resolve) => {
    const janela = document.getElementById('janela-confirmar');
    document.getElementById('titulo-confirmar').textContent = titulo;
    document.getElementById('texto-confirmar').textContent = texto;
    const btn = document.getElementById('btn-confirmar');
    btn.textContent = rotuloSim || 'Confirmar';

    let respondido = false;
    function limpar() {
      janela.removeEventListener('close', aoFechar);
      btn.removeEventListener('click', aoSim);
    }
    function aoSim() { respondido = true; limpar(); janela.close(); resolve(true); }
    function aoFechar() { limpar(); if (!respondido) resolve(false); }

    btn.addEventListener('click', aoSim);
    janela.addEventListener('close', aoFechar);
    janela.showModal();
  });
}
