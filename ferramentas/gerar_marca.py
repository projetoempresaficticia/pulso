#!/usr/bin/env python3
"""Prepara a marca e o fundo do Pulso.

A marca é o balão de conversa branco sobre o quadrado índigo. Vai como PNG
com transparência: o quadrado tem cantos redondos e um gradiente, que uma
máscara de um canal só perderia.

O fundo da entrada é claro, com as ondas índigo em baixo à esquerda e o
balão grande no mesmo canto. O espaço livre é em cima à direita — é lá que
o cartão de entrada assenta.

Produz:
  web/marca/pu-marca.png / .webp    a marca, para o cabeçalho
  web/marca/pu-512.png              a mesma, para partilha
  web/marca/fundo-entrada.webp      o fundo, largo
  web/marca/fundo-entrada.jpg       reserva para quem não suporte WebP
  apple-touch-icon.png              180x180 sobre branco
  favicon-32.png / favicon.ico
"""

import pathlib
from PIL import Image

RAIZ = pathlib.Path(__file__).resolve().parent.parent
DESC = pathlib.Path(r"C:/Users/devel/Downloads")
ICONE = DESC / "ChatGPT Image 6 de set. de 2026, 14_18_03.png"
FUNDO = DESC / "ChatGPT Image 6 de set. de 2026, 14_20_36.png"


def quadrado(caixa):
    """Alarga a caixa para ficar quadrada. Preenche, nunca estica."""
    x0, y0, x1, y1 = caixa
    lado = max(x1 - x0, y1 - y0)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    meio = lado // 2
    return (cx - meio, cy - meio, cx - meio + lado, cy - meio + lado)


def main():
    destino = RAIZ / 'web' / 'marca'
    destino.mkdir(parents=True, exist_ok=True)

    if ICONE.is_file():
        im = Image.open(ICONE).convert('RGBA')
        # O ícone traz uma sombra suave à volta. O alfa dela não é zero, por
        # isso entra no getbbox() e o recorte sai com uma margem de ar —
        # que no cabeçalho, a 36px, dá um quadrado visivelmente mais pequeno
        # do que os das outras apps. Corta-se pelo alfa forte.
        solido = im.getchannel('A').point(lambda a: 255 if a > 200 else 0)
        caixa = quadrado(solido.getbbox())
        marca = im.crop(caixa)
        print('marca recortada em', caixa, '->', caixa[2] - caixa[0], 'px de lado')

        def redim(lado):
            return marca.resize((lado, lado), Image.LANCZOS)

        # No cabeçalho aparece a 36px. Guardar 512 seriam centenas de KB
        # para desenhar 36; 128 chega para densidade tripla.
        pequena = redim(128)
        alvo = destino / 'pu-marca.webp'
        pequena.save(alvo, 'WEBP', quality=92, method=6)
        print(f'escrito web/marca/pu-marca.webp  {alvo.stat().st_size/1024:.0f} KB')
        reserva = destino / 'pu-marca.png'
        pequena.save(reserva, optimize=True)
        print(f'escrito web/marca/pu-marca.png   {reserva.stat().st_size/1024:.0f} KB')

        redim(512).save(destino / 'pu-512.png', optimize=True)
        print('escrito web/marca/pu-512.png')

        # O iOS não respeita transparência no ícone do ecrã inicial: o que
        # fosse transparente saía preto. Compõe-se sobre branco.
        base = Image.new('RGBA', (180, 180), (255, 255, 255, 255))
        base.alpha_composite(redim(180), (0, 0))
        base.convert('RGB').save(RAIZ / 'apple-touch-icon.png', optimize=True)
        print('escrito apple-touch-icon.png')

        redim(32).save(RAIZ / 'favicon-32.png', optimize=True)
        redim(256).save(RAIZ / 'favicon.ico',
                        sizes=[(16, 16), (32, 32), (48, 48), (64, 64)])
        print('escritos favicon-32.png e favicon.ico')
    else:
        print('AVISO: não encontro o ícone em', ICONE)

    if FUNDO.is_file():
        fundo = Image.open(FUNDO).convert('RGB')
        print('fundo original', fundo.size, f'{FUNDO.stat().st_size/1024:.0f} KB')

        largo = destino / 'fundo-entrada.webp'
        fundo.save(largo, 'WEBP', quality=88, method=6)
        print(f'escrito web/marca/fundo-entrada.webp {largo.stat().st_size/1024:.0f} KB')

        reserva = destino / 'fundo-entrada.jpg'
        fundo.save(reserva, 'JPEG', quality=86, optimize=True, progressive=True)
        print(f'escrito web/marca/fundo-entrada.jpg  {reserva.stat().st_size/1024:.0f} KB')
    else:
        print('AVISO: não encontro o fundo em', FUNDO)


if __name__ == '__main__':
    main()
