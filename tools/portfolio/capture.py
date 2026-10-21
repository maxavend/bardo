#!/usr/bin/env python3
"""Captures every portfolio screen in light and dark with Bardo's design review.

    python3 -I tools/portfolio/capture.py <Bardo.app> <homes folder> <output folder> [filter]

`<homes folder>` holds the seeded homes (`library`, `empty`, `recovery`). Each shot runs
against a fresh APFS clone of its home, so scenarios that transcribe, identify speakers
or move to the Trash never change the seed. Windows are placed on the Retina screen and
captured with their sheets and popovers. `filter` limits the run to shots whose path
contains it.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BUNDLE = "com.maxavend.bardo.portfolio"
SIZE = "1280x800"

# Library order (newest first): 0 Revisión de diseño, 1 Nota de voz, 2 Retro (pending),
# 3 Llamada con Javiera, 4 Demo API, 5 Entrevista Carolina, 6 Test de usabilidad,
# 7 Kickoff (failed).
LIVE_WAIT = os.environ.get("BARDO_LIVE_WAIT", "3")

SHOTS = [
    # folder, file, scenario, options
    ("00-portada", "01-reunion-transcrita", "open:0", {"size": "1440x900"}),
    ("00-portada", "02-busqueda-en-la-biblioteca", "search:reprogramar+open:6", {"size": "1440x900"}),

    ("01-primer-uso", "01-bienvenida", "launch", {"welcome": True}),
    ("01-primer-uso", "02-biblioteca-vacia", "launch", {"home": "empty"}),

    ("02-biblioteca", "01-todas-las-conversaciones", "open:0", {}),
    ("02-biblioteca", "02-favoritas", "section:favorites", {}),
    ("02-biblioteca", "03-grabadas", "section:recorded", {}),
    ("02-biblioteca", "04-importadas", "section:imported", {}),
    ("02-biblioteca", "05-sin-seleccion", "open:0+deselect", {}),
    ("02-biblioteca", "06-barra-lateral-oculta", "open:5+sidebar:hidden", {}),
    ("02-biblioteca", "07-navegacion-con-teclado", "open:0+focusList:1+press:down+press:down+press:down", {}),

    ("03-busqueda", "01-buscar-reprogramar", "search:reprogramar+open:6", {}),
    ("03-busqueda", "02-buscar-carolina", "search:Carolina+open:5", {}),
    ("03-busqueda", "03-resultado-en-transcripcion", "search:reprogramar+open:1", {}),
    ("03-busqueda", "04-sin-resultados", "deselect+search:facturación electrónica", {}),

    ("04-grabar", "01-nueva-grabacion", "open:0+newRecording", {}),
    ("04-grabar", "02-grabando-reunion", "open:0+recordingBanner", {}),
    ("04-grabar", "03-grabaciones-interrumpidas", "open:0", {"home": "recovery"}),
    ("04-grabar", "04-recuperar-grabacion", "open:0+recovery", {"home": "recovery"}),

    ("05-transcribir", "01-conversacion-sin-transcribir", "open:2", {}),
    ("05-transcribir", "02-escuchando-la-conversacion", "open:2+mute:0.01+transcribe+wait:0.6", {}),
    ("05-transcribir", "03-transcribiendo-en-vivo", f"open:2+mute:0.01+transcribe+wait:{LIVE_WAIT}", {}),
    ("05-transcribir", "04-transcripcion-terminada", "open:2+mute:0.01+transcribe+wait:12", {}),
    ("05-transcribir", "05-transcripcion-fallida", "open:7", {}),

    ("06-leer-y-escuchar", "01-reunion-por-pistas", "open:0", {}),
    ("06-leer-y-escuchar", "02-reproduciendo", "open:0+mute:0.01+seek:31+play+wait:2.5", {}),
    ("06-leer-y-escuchar", "03-pistas-de-audio", "open:0+mute:0.01+seek:31+tracks", {"appearances": ["dark"]}),
    ("06-leer-y-escuchar", "04-entrevista-importada", "open:5", {}),
    ("06-leer-y-escuchar", "05-nota-de-voz", "open:1", {}),
    ("06-leer-y-escuchar", "06-detalles-de-la-conversacion", "open:0+inspector", {}),

    ("07-hablantes", "01-hablantes-sin-nombre", "open:4", {}),
    ("07-hablantes", "02-nombrar-hablantes", "open:4+speakers", {}),
    ("07-hablantes", "03-confirmar-nombres", "open:5+mute:0.01+identify+wait:0.2", {}),
    ("07-hablantes", "04-hablantes-nombrados", "open:6", {}),

    ("08-editar", "01-editar-fragmento", "open:6+edit:5", {}),
    ("08-editar", "02-renombrar-conversacion", "open:6+rename", {}),
    ("08-editar", "03-mover-a-la-papelera", "open:7+delete", {}),

    ("09-ajustes", "01-general", "settings+settingsTab:general", {"window": "settings"}),
    ("09-ajustes", "02-grabacion", "settings+settingsTab:recording", {"window": "settings"}),
    ("09-ajustes", "03-transcripcion", "settings+settingsTab:transcription+wait:15", {"window": "settings"}),
    ("09-ajustes", "04-almacenamiento", "settings+settingsTab:storage+wait:2", {"window": "settings"}),
    ("09-ajustes", "05-privacidad", "settings+settingsTab:privacy", {"window": "settings"}),
]


def pixel_area(image: Path) -> int:
    output = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(image)],
                            capture_output=True, text=True).stdout.split()
    return int(output[-3]) * int(output[-1])


SUPPORT = Path("Library/Application Support/Bardo")


def working_home(home: Path) -> Path:
    """A fixed working copy of `home`, refreshed before every shot except for its models.

    Core ML optimizes the speech model once per model location, so keeping the models at
    the same path lets every transcription after the first start right away."""
    work = home.parent / f"work-{home.name}"
    if not (work / SUPPORT / "Models").exists():
        shutil.rmtree(work, ignore_errors=True)
        subprocess.run(["cp", "-cR", str(home), str(work)], check=True)
        return work
    for entry in (work / SUPPORT).iterdir():
        if entry.name != "Models":
            shutil.rmtree(entry) if entry.is_dir() else entry.unlink()
    for entry in (home / SUPPORT).iterdir():
        if entry.name != "Models":
            subprocess.run(["cp", "-cR", str(entry), str(work / SUPPORT / entry.name)], check=True)
    return work


def run(app: Path, home: Path, scenario: str, appearance: str, options: dict, out: Path) -> list[Path]:
    with tempfile.TemporaryDirectory(dir=home.parent) as temporary:
        clone = working_home(home)
        capture = Path(temporary) / "capture"
        arguments = [
            "-BardoDesignCapture", str(capture),
            "-BardoDesignScenario", scenario,
            "-BardoDesignAppearance", appearance,
            "-BardoDesignWindowSize", options.get("size", SIZE),
            "-BardoDesignScreen", "sharpest",
            "-BardoDesignComposite", "YES",
            "-BardoDesignRenderer", "window",
            "-BardoDesignMicrophone", "Micrófono del MacBook Air",
            "-AppleShowScrollBars", "WhenScrolling",
            "-BardoDesignForceActive", "YES",
        ]
        if options.get("welcome"):
            arguments += ["-BardoDesignWelcome", "YES"]
        subprocess.run(
            ["open", "-n", "-W", str(app), "--env", f"CFFIXED_USER_HOME={clone}", "--args", *arguments],
            check=True, timeout=600,
        )
        images = sorted(capture.glob("*.png"))
        # The main window is the largest capture; Settings is the smaller window.
        images = sorted(images, key=pixel_area, reverse=options.get("window") != "settings")[:1]
        for image in images:
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(image), out)
        for error in capture.glob("*-error.txt"):
            print(f"  capture error: {error.read_text()}", flush=True)
        return images


def main() -> None:
    app, homes, output = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    only = sys.argv[4] if len(sys.argv) > 4 else ""
    if not os.environ.get("BARDO_SKIP_WARMUP") and any("transcribe" in shot[2] or "identify" in shot[2] for shot in SHOTS
           if not only or only in f"{shot[0]}/{shot[1]}"):
        # Let Core ML optimize the models at the working copy's path once.
        run(app, homes / "library", "open:2+mute:0.01+transcribe+wait:300+open:1+identify+wait:30",
            "light", {}, homes / "warmup.png")
        print("models warmed up", flush=True)
    for folder, name, scenario, options in SHOTS:
        if only and only not in f"{folder}/{name}":
            continue
        home = homes / options.get("home", "library")
        # The tracks popover's material only captures faithfully in dark.
        for appearance in options.get("appearances", ("light", "dark")):
            target = output / folder / f"{name}-{'claro' if appearance == 'light' else 'oscuro'}.png"
            saved = run(app, home, scenario, appearance, options, target)
            print(f"{target.relative_to(output)}: {len(saved)} image(s)", flush=True)


if __name__ == "__main__":
    main()
