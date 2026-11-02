"""Splits Bardo's AI v2 head into the two layers of the app icon: the face with its eyes,
and the beret with its feather and pin, both framed on Icon Composer's 1024 pt canvas.

The face is the cream skin (warm, with green close to red, unlike the violet felt, the red
pin and the lavender feather) plus the eyes it encloses. The face layer keeps the whole
head inside a slightly grown face outline, so the beret layer, cut with a soft edge, always
sits on the same pixels and the two together give back the original image.

    ~/.local/share/blender-agent/venv/bin/python -I design/mascota/image-v2/capas_icono.py
"""

import os

import cv2
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "bardo-mascota-original.png")
ASSETS = os.path.join(HERE, "..", "..", "..", "Bardo", "Resources", "AppIcon.icon", "Assets")

CANVAS = 1024
FILL = 0.80  # share of the canvas the head's longer side takes
LIFT = 0.0  # the head sits optically centred; nudge up (positive) if it reads low


def face_mask(rgba):
    r, g, b, a = [rgba[..., i].astype(np.float32) for i in range(4)]
    skin = (r > 90) & (g > 0.72 * r) & ((r - b) > 6) & (a > 128)
    skin = cv2.morphologyEx(skin.astype(np.uint8), cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
    # The face is the largest piece of skin; the feather's warm highlights are not part of it.
    count, labels, stats, _ = cv2.connectedComponentsWithStats(skin, 8)
    face = (labels == 1 + np.argmax(stats[1:, cv2.CC_STAT_AREA])).astype(np.uint8)
    # The eyes are holes inside the face.
    contours, _ = cv2.findContours(face, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    filled = np.zeros_like(face)
    cv2.drawContours(filled, contours, -1, 1, -1)
    return filled


def bounds(image):
    ys, xs = np.nonzero(np.asarray(image)[..., 3] > 8)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def place(image, box):
    """Scales the head so its longer side is FILL of the canvas, centred."""
    w, h = box[2] - box[0], box[3] - box[1]
    scale = CANVAS * FILL / max(w, h)
    size = (round(image.width * scale), round(image.height * scale))
    scaled = image.resize(size, Image.LANCZOS)
    cx, cy = (box[0] + box[2]) / 2 * scale, (box[1] + box[3]) / 2 * scale
    out = Image.new("RGBA", (CANVAS, CANVAS))
    out.alpha_composite(scaled, (round(CANVAS / 2 - cx), round(CANVAS / 2 - cy - LIFT * CANVAS)))
    return out


def main():
    source = Image.open(SOURCE).convert("RGBA")
    rgba = np.asarray(source).copy()
    face = face_mask(rgba)

    # Soft edge where the beret meets the face, and a face layer that reaches under it.
    # Elsewhere on the face's outline the beret layer stays empty, so it leaves no fringe.
    alpha = rgba[..., 3].astype(np.float32)
    soft = cv2.GaussianBlur(face.astype(np.float32), (0, 0), 1.2)
    beret = ((alpha > 128) & (face == 0)).astype(np.uint8)
    near_beret = cv2.dilate(beret, np.ones((7, 7), np.uint8)).astype(np.float32)
    under = cv2.dilate(face, np.ones((15, 15), np.uint8)).astype(np.float32)

    face_layer = rgba.copy()
    face_layer[..., 3] = np.round(alpha * under).astype(np.uint8)
    beret_layer = rgba.copy()
    beret_layer[..., 3] = np.round(alpha * (1 - soft) * near_beret).astype(np.uint8)

    box = bounds(source)
    for name, layer in (("cara.png", face_layer), ("boina.png", beret_layer)):
        place(Image.fromarray(layer), box).save(os.path.join(ASSETS, name), optimize=True)


if __name__ == "__main__":
    main()
