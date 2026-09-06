// Pulso — garante que ninguém fica preso numa versão velha.
//
// O PROBLEMA. O GitHub Pages manda `Cache-Control: max-age=600` no HTML,
// e não deixa mudar isso. Durante dez minutos o browser serve o HTML
// guardado sem sequer perguntar ao servidor. E como é o HTML que diz
// quais são os `?v=` do CSS e do JS, um HTML velho aponta para ficheiros
// velhos: a marcação de versão nos assets não salva nada, porque a porta
// de entrada é a que está em cache.
//
// Foi assim que, no Portal das Finanças, o Germano viu a lista de boletos
// com o desenho antigo horas depois de ele ter sido substituído. Este
// ficheiro anda de app em app desde então.
//
// A SOLUÇÃO. Cada página traz a versão do site num <meta>. Ao abrir,
// pergunta-se ao servidor qual é a versão atual (com `no-store`, que o
// obriga a ir mesmo lá) e, se não bater certo, recarrega-se com a versão
// no endereço. Endereço diferente quer dizer entrada diferente na cache,
// por isso o browser vai buscar o HTML novo em vez de reusar o velho.
//
// Cuidados:
//   • recarrega no máximo UMA vez por página e por versão, guardado em
//     sessionStorage, para nunca entrar em ciclo;
//   • sem rede, ou se o versao.json falhar, segue com o que tem: mais
//     vale a página velha do que página nenhuma.

(function () {
  const meta = document.querySelector('meta[name="pu-versao"]');
  if (!meta || !meta.content) return;
  const minha = meta.content;

  function jaTentei(versao) {
    const chave = 'pc-recarga:' + window.location.pathname + ':' + versao;
    try {
      if (sessionStorage.getItem(chave)) return true;
      sessionStorage.setItem(chave, '1');
      return false;
    } catch (e) {
      // janela anónima ou site data bloqueado: não arriscar o ciclo
      return true;
    }
  }

  fetch('versao.json?t=' + Date.now(), { cache: 'no-store' })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (d) {
      if (!d || !d.versao || d.versao === minha) return;
      if (jaTentei(d.versao)) return;

      const u = new URL(window.location.href);
      u.searchParams.set('v', d.versao);
      window.location.replace(u.toString());
    })
    .catch(function () { /* offline: fica-se com esta versão */ });
})();
