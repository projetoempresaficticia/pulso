# Pulso

O canal **rápido** do ecossistema [Prepara Portugal](https://github.com/projetoempresaficticia).
Conversas e grupos em tempo real, entre pessoas identificadas por um número
fictício de telemóvel português (9XX XXX XXX) ligado à cédula.

**Três canais, não confundir:** o Gmail das empresas (real) · o
[AeroMail](https://projetoempresaficticia.github.io/aeromail/) (formal, fica
registado) · o Pulso (rápido, este).

- **Aplicação:** https://projetoempresaficticia.github.io/pulso/
- **Biblioteca visual:** https://projetoempresaficticia.github.io/pulso/biblioteca.html

**Estado:** identidade visual definida, aplicação por construir.
Antes chamava-se `pp-mensagens`.

## Como está montado

Supabase (Postgres + Auth + Realtime) e GitHub Pages. HTML e JS simples, sem
framework e sem passo de compilação.

| pasta | o que lá está |
|---|---|
| `sql/` | as migrações, por ordem, cada uma com o porquê escrito no topo |
| `web/biblioteca/` | o CSS e o JS partilhados por todos os ecrãs |
| `web/marca/` | o ícone e o fundo da entrada, já reduzidos |
| `ferramentas/` | `gerar_marca.py` prepara a marca; `versoes.py` carimba os `?v=` |
| `biblioteca.html` | a biblioteca visual — não faz parte da app |

## Antes de publicar

```
python ferramentas/versoes.py
```

O GitHub Pages manda `Cache-Control: max-age=600` no HTML e não deixa mudar
isso. Sem este passo, um HTML em cache continua a apontar para o CSS e o JS
velhos durante dez minutos, e uma correção parece não pegar. O
`web/atualizar.js` é a outra metade da solução.

Documentação do projeto (PRDs e decisões) em
[prepara-portugal-docs](https://github.com/projetoempresaficticia/prepara-portugal-docs).
