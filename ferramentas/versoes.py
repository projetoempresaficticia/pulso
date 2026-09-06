#!/usr/bin/env python3
"""Carimba as versões do Pulso.

Faz duas coisas, e as duas são necessárias:

1. Reescreve os `?v=` dos ficheiros locais com o sha1 do próprio
   ficheiro. Sem isto o browser serve uma cópia velha do JS ou do CSS.

2. Escreve `versao.json` e o `<meta name="pu-versao">` de cada página,
   com um resumo de TODOS os ficheiros versionados. Isto existe porque o
   ponto 1 sozinho não chega: o GitHub Pages manda
   `Cache-Control: max-age=600` no HTML e não deixa mudar isso, por isso
   um HTML em cache continua a apontar para os `?v=` velhos e a página
   fica presa dez minutos. O `web/atualizar.js` compara o meta com o
   versao.json e recarrega quando não batem.

Uso:
    python ferramentas/versoes.py            verifica e corrige
    python ferramentas/versoes.py --conferir só verifica, devolve 1 se
                                             houver algo desatualizado
"""

import hashlib
import json
import pathlib
import re
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent

# só ficheiros locais: os CDN e as fontes não levam ?v=
PADRAO = re.compile(r'(?P<attr>src|href)="(?P<ficheiro>(?!https?:)[^"?]+)\?v=(?P<versao>[^"]*)"')
META = re.compile(r'<meta name="pu-versao" content="(?P<versao>[^"]*)"\s*/?>')
# Para o cálculo do resumo, apagar o meta TEM de apagar também o espaço
# em branco que ficaria antes dele. Sem isso, uma página que já tem o
# meta reduz-se a um texto ligeiramente diferente da que ainda não tem
# (sobra a mudança de linha e a indentação), o resumo muda de passagem
# para passagem e o script nunca estabiliza.
META_RESUMO = re.compile(r'\s*<meta name="pu-versao"[^>]*>')


def resumo(caminho: pathlib.Path) -> str:
    return hashlib.sha1(caminho.read_bytes()).hexdigest()[:8]


def main() -> int:
    conferir = '--conferir' in sys.argv
    problemas = 0
    paginas = sorted(RAIZ.glob('*.html'))
    versionados = set()

    # ── passo 1: os ?v= de cada ficheiro ──────────────────────────────
    textos = {}
    for html in paginas:
        texto = html.read_text(encoding='utf-8')

        def troca(m: re.Match) -> str:
            nonlocal problemas
            alvo = (html.parent / m.group('ficheiro')).resolve()
            if not alvo.is_file():
                print(f'  FALTA    {html.name} -> {m.group("ficheiro")}')
                problemas += 1
                return m.group(0)
            versionados.add(alvo)
            novo = resumo(alvo)
            if novo != m.group('versao'):
                print(f'  {"desatualizado" if conferir else "corrigido"}'
                      f'  {html.name} -> {m.group("ficheiro")}  {m.group("versao")} -> {novo}')
                problemas += 1
            return f'{m.group("attr")}="{m.group("ficheiro")}?v={novo}"'

        textos[html] = PADRAO.sub(troca, texto)

    # ── passo 2: a versão do site inteiro ─────────────────────────────
    # Resumo de todos os assets versionados MAIS o HTML já corrigido: se
    # mudar uma vírgula em qualquer sítio, a versão muda e quem tiver a
    # página velha em cache recarrega.
    #
    # O <meta> da versão sai do cálculo, senão isto era circular:
    # escrever a versão no ficheiro mudava o ficheiro, que mudava a
    # versão, que obrigava a reescrever, para sempre.
    acumulador = hashlib.sha1()
    for f in sorted(versionados):
        acumulador.update(f.read_bytes())
    for html in paginas:
        acumulador.update(META_RESUMO.sub('', textos[html]).encode('utf-8'))
    versao_site = acumulador.hexdigest()[:12]

    for html in paginas:
        texto = textos[html]
        atual = META.search(texto)
        if atual:
            if atual.group('versao') != versao_site:
                problemas += 1
                texto = META.sub(
                    f'<meta name="pu-versao" content="{versao_site}" />', texto, count=1)
        else:
            problemas += 1
            print(f'  sem meta de versão: {html.name}')
            texto = texto.replace(
                '<meta name="viewport"',
                f'<meta name="pu-versao" content="{versao_site}" />\n  <meta name="viewport"',
                1)
        textos[html] = texto

    ficheiro_versao = RAIZ / 'versao.json'
    conteudo = json.dumps({'versao': versao_site}, ensure_ascii=False) + '\n'
    versao_gravada = None
    if ficheiro_versao.is_file():
        try:
            versao_gravada = json.loads(ficheiro_versao.read_text(encoding='utf-8')).get('versao')
        except ValueError:
            pass

    if not conferir:
        for html in paginas:
            html.write_text(textos[html], encoding='utf-8')
        ficheiro_versao.write_text(conteudo, encoding='utf-8')

    if versao_gravada != versao_site:
        problemas += 1
        print(f'  versão do site: {versao_gravada} -> {versao_site}')

    if problemas == 0:
        print(f'Tudo carimbado. Versão do site: {versao_site}')
        return 0
    if conferir:
        print(f'\n{problemas} por corrigir. Corra sem --conferir.')
        return 1
    print(f'\nAtualizado. Versão do site: {versao_site}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
