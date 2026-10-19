#!/usr/bin/env python3
"""Turns the captures into a portfolio folder: one folder per flow, a README and a gallery.

    python3 -I tools/portfolio/organize.py <captures> <portfolio folder>
"""
import html
import shutil
import sys
from pathlib import Path

FLOWS = {
    "00-portada": ("Portada", "Vistas principales a mayor tamaño (2880 × 1800 px) para abrir el caso."),
    "01-primer-uso": ("Primer uso", "Bienvenida y biblioteca vacía con sus dos llamadas a la acción."),
    "02-biblioteca": ("Biblioteca", "Filtros de la barra lateral, favoritas, estados de selección y navegación con teclado."),
    "03-busqueda": ("Búsqueda", "Una sola búsqueda para toda la biblioteca, con fragmentos, coincidencias resaltadas y estado sin resultados."),
    "04-grabar": ("Grabar", "Nueva grabación, grabación en curso y recuperación de una grabación interrumpida."),
    "05-transcribir": ("Transcribir", "Del audio sin transcribir al texto que llega en vivo, el resultado por pistas y el error recuperable."),
    "06-leer-y-escuchar": ("Leer y escuchar", "Transcripciones por hablante, reproducción con resaltado palabra a palabra, pistas y detalles."),
    "07-hablantes": ("Hablantes", "Identificación local de hablantes, revisión de voces y resultado con nombres."),
    "08-editar": ("Editar", "Corrección de un fragmento conservando el original, renombrar y mover a la Papelera."),
    "09-ajustes": ("Ajustes", "Las cinco pestañas de Ajustes."),
}

SCREENS = {
    "00-portada/01-reunion-transcrita": "Reunión transcrita por pistas, con participantes con nombre y correcciones manuales.",
    "00-portada/02-busqueda-en-la-biblioteca": "Búsqueda de «reprogramar» en todas las conversaciones, con el resultado abierto.",
    "01-primer-uso/01-bienvenida": "Bienvenida: qué hace Bardo y la promesa de privacidad antes de descargar los recursos.",
    "01-primer-uso/02-biblioteca-vacia": "Biblioteca vacía con «Nueva grabación» e «Importar audio».",
    "02-biblioteca/01-todas-las-conversaciones": "Biblioteca con ocho conversaciones de la semana y una reunión abierta.",
    "02-biblioteca/02-favoritas": "Filtro Favoritas.",
    "02-biblioteca/03-grabadas": "Filtro Grabadas: reuniones, notas de voz y audio del Mac.",
    "02-biblioteca/04-importadas": "Filtro Importadas: una entrevista grabada fuera de Bardo.",
    "02-biblioteca/05-sin-seleccion": "Sin conversación seleccionada.",
    "02-biblioteca/06-barra-lateral-oculta": "Barra lateral oculta para leer con más espacio.",
    "02-biblioteca/07-navegacion-con-teclado": "Navegación con flechas: la selección y el contenido se mueven juntos.",
    "03-busqueda/01-buscar-reprogramar": "Resultados con fragmentos y el test de usabilidad abierto con las coincidencias resaltadas.",
    "03-busqueda/02-buscar-carolina": "Búsqueda por participante: la entrevista con Carolina y las conversaciones que la mencionan.",
    "03-busqueda/03-resultado-en-transcripcion": "La coincidencia resaltada dentro de la nota de voz.",
    "03-busqueda/04-sin-resultados": "Estado sin resultados.",
    "04-grabar/01-nueva-grabacion": "Hoja de nueva grabación: micrófono, reunión en este Mac o audio interno.",
    "04-grabar/02-grabando-reunion": "Grabación en curso: tu voz y el audio del Mac en pistas separadas.",
    "04-grabar/03-grabaciones-interrumpidas": "Aviso de una grabación interrumpida a salvo.",
    "04-grabar/04-recuperar-grabacion": "Revisión de grabaciones interrumpidas: recuperar o mover a la Papelera.",
    "05-transcribir/01-conversacion-sin-transcribir": "Conversación aún sin transcribir.",
    "05-transcribir/02-escuchando-la-conversacion": "Primeros segundos: el texto empieza a aparecer mientras Bardo escucha la conversación.",
    "05-transcribir/03-transcribiendo-en-vivo": "El texto aparece a medida que Bardo lo reconoce, con progreso en la lista y la barra lateral.",
    "05-transcribir/04-transcripcion-terminada": "Resultado por pistas: «Tú» desde el micrófono y «Los demás» desde el audio del Mac.",
    "05-transcribir/05-transcripcion-fallida": "Transcripción fallida con el audio a salvo y «Intentar de nuevo».",
    "06-leer-y-escuchar/01-reunion-por-pistas": "Reunión con tres participantes con nombre.",
    "06-leer-y-escuchar/02-reproduciendo": "Reproducción: la palabra que suena se resalta en la transcripción.",
    "06-leer-y-escuchar/03-pistas-de-audio": "Pistas: escuchar todo, solo tu micrófono o solo a los demás (modo oscuro).",
    "06-leer-y-escuchar/04-entrevista-importada": "Entrevista importada con dos participantes.",
    "06-leer-y-escuchar/05-nota-de-voz": "Nota de voz de una sola persona, leída como un párrafo.",
    "06-leer-y-escuchar/06-detalles-de-la-conversacion": "Detalles de la conversación: origen, idioma y tiempos de procesamiento.",
    "07-hablantes/01-hablantes-sin-nombre": "Participantes identificados, aún sin nombre.",
    "07-hablantes/02-nombrar-hablantes": "Revisar hablantes: escuchar una muestra de cada voz y nombrarla.",
    "07-hablantes/03-confirmar-nombres": "Al terminar de identificar las voces, Bardo abre la revisión con los nombres que ya conocía.",
    "07-hablantes/04-hablantes-nombrados": "Test de usabilidad con «Tú» y «Sofía», y correcciones marcadas como editadas.",
    "08-editar/01-editar-fragmento": "Editar un fragmento ya corregido («Nueva York» → «Ñuñoa»).",
    "08-editar/02-renombrar-conversacion": "Renombrar una conversación.",
    "08-editar/03-mover-a-la-papelera": "Confirmación antes de mover a la Papelera de macOS.",
    "09-ajustes/01-general": "General: apariencia.",
    "09-ajustes/02-grabacion": "Grabación.",
    "09-ajustes/03-transcripcion": "Transcripción: idioma, reuniones por pistas y recursos locales.",
    "09-ajustes/04-almacenamiento": "Almacenamiento.",
    "09-ajustes/05-privacidad": "Privacidad.",
}

README = """# Bardo — capturas para portafolio

Capturas de Bardo, app nativa de macOS que graba o importa conversaciones y las convierte
en transcripciones privadas, hechas en el propio Mac.

## Contenido

- **Resolución:** Retina 2×. La ventana principal mide 2560 × 1600 px (1280 × 800 pt) y
  la portada 2880 × 1800 px. Ajustes conserva su tamaño nativo.
- **Apariencia:** cada pantalla en claro (`-claro.png`) y oscuro (`-oscuro.png`), salvo
  «Pistas de audio», solo en oscuro.
- **Formato:** PNG sin compresión con pérdida y esquinas transparentes, listo para montar
  sobre cualquier fondo o mockup.
- `index.html` abre una galería con todas las capturas.

## Datos de ejemplo

Las capturas muestran una semana ficticia de un equipo de producto que rediseña **Nido**,
una app para agendar visitas de enfermería a domicilio. Las conversaciones se conectan:
la entrevista a Carolina y el test de usabilidad alimentan la síntesis de research, la
demo de la API y la retro, y todo llega a la revisión de diseño del lunes. Personas,
empresa y conversaciones son inventadas.

El audio se generó con voces de macOS y se transcribió con los modelos reales de Bardo
(Whisper y SpeakerKit), así que transcripciones, tiempos y participantes salen del
producto funcionando. Algunas palabras mal reconocidas quedaron como correcciones
manuales: Bardo las muestra como «Editado» y conserva el texto original.

## Flujos y pantallas
"""


def main() -> None:
    captures, portfolio = Path(sys.argv[1]), Path(sys.argv[2])
    if portfolio.exists():
        shutil.rmtree(portfolio)
    portfolio.mkdir(parents=True)
    readme = [README]
    gallery = []
    for folder, (title, summary) in FLOWS.items():
        images = sorted((captures / folder).glob("*.png"))
        if not images:
            continue
        destination = portfolio / folder
        destination.mkdir()
        readme.append(f"\n### {folder} · {title}\n\n{summary}\n")
        gallery.append(f"<h2>{html.escape(title)}</h2><p>{html.escape(summary)}</p>")
        screens = sorted({image.name.rsplit("-", 1)[0] for image in images})
        for screen in screens:
            description = SCREENS.get(f"{folder}/{screen}", "")
            readme.append(f"- `{screen}` — {description}")
            gallery.append(f"<h3>{html.escape(screen)}</h3><p>{html.escape(description)}</p><div class=row>")
            for image in images:
                if image.name.rsplit("-", 1)[0] == screen:
                    shutil.copy2(image, destination / image.name)
                    path = f"{folder}/{image.name}"
                    gallery.append(f'<a href="{html.escape(path)}"><img loading=lazy src="{html.escape(path)}" '
                                   f'alt="{html.escape(description)}"></a>')
            gallery.append("</div>")
    (portfolio / "README.md").write_text("\n".join(readme) + "\n")
    (portfolio / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>Bardo — portafolio</title><style>"
        ":root{color-scheme:light dark}body{font:15px -apple-system,system-ui;margin:32px auto;max-width:1400px;padding:0 16px}"
        "h2{margin-top:48px}h3{margin:24px 0 4px;font-weight:600}p{margin:0 0 12px;color:GrayText}"
        ".row{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}"
        "img{width:100%;height:auto;filter:drop-shadow(0 8px 24px rgb(0 0 0/.25))}</style>"
        "<h1>Bardo — capturas para portafolio</h1>" + "".join(gallery)
    )
    count = len(list(portfolio.glob("*/*.png")))
    print(f"{count} capturas en {portfolio}")


if __name__ == "__main__":
    main()
