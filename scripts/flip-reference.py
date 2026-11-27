#!/usr/bin/env python3
"""The reference numbers of E-GOLD-6: NVlabs FLIP (`flip-evaluator`) on synthetic-corpus pairs.

Not part of the gate and not a dependency of the engine: it is run by hand, outside the package, in a virtual
environment that has the reference installed, and its output is pasted into
`Tests/HearthEngineTests/FLIPReferenceTests.swift`.

  python3 -m venv /tmp/flip && /tmp/flip/bin/pip install flip-evaluator==1.7 numpy
  /tmp/flip/bin/python -I scripts/flip-reference.py

The images are rebuilt here from `Sources/HearthHarness/Corpus/SyntheticCorpus.swift` (integer arithmetic, so
the port is exact); the test checks each image's `PixelImage.sha256` against the hash printed here, so a port that
drifted from the Swift generator fails there and not as a FLIP mismatch.

The 99th percentile is the nearest rank over the reference's own map, the definition `FLIPResult` uses.
"""
import hashlib
import math

SATURATED = [(255, 0, 0), (0, 255, 255), (0, 255, 0), (255, 0, 255), (0, 0, 255), (255, 255, 0)]
MUTED = [(160, 40, 40), (40, 160, 40), (40, 40, 160), (160, 160, 40), (160, 40, 160), (40, 160, 160)]
GLYPHS = [
    [0b111, 0b101, 0b101, 0b101, 0b111], [0b010, 0b110, 0b010, 0b010, 0b111], [0b111, 0b001, 0b111, 0b100, 0b111],
    [0b111, 0b001, 0b111, 0b001, 0b111], [0b101, 0b101, 0b111, 0b001, 0b001], [0b111, 0b100, 0b111, 0b001, 0b111],
    [0b111, 0b100, 0b111, 0b101, 0b111], [0b111, 0b001, 0b001, 0b001, 0b001], [0b111, 0b101, 0b111, 0b101, 0b111],
    [0b111, 0b101, 0b111, 0b001, 0b111],
]
PROJECTIONS = {"diamond48x28": (48, 28), "diamond2to1": (64, 32), "orthogonal": (32, 32)}


class Image:
    def __init__(self, width, height, fill):
        self.width, self.height = width, height
        self.pixels = [tuple(fill)] * (width * height)

    def set(self, x, y, rgba):
        if 0 <= x < self.width and 0 <= y < self.height:
            self.pixels[y * self.width + x] = tuple(rgba)

    def sha256(self):
        h = hashlib.sha256()
        h.update(self.width.to_bytes(4, "little") + self.height.to_bytes(4, "little"))
        h.update(bytes(v for p in self.pixels for v in p))
        return h.hexdigest()


def opaque(rgb):
    return (*rgb, 255)


def ramp(index, count):
    return index * 255 // (count - 1) if count > 1 else 255


def colour_ramp(width, height):
    image = Image(width, height, (0, 0, 0, 255))
    for y in range(height):
        for x in range(width):
            red = ramp(x, width)
            image.set(x, y, (red, ramp(y, height), 255 - red, 255))
    return image


def saturated_neighbours(cell, columns, rows):
    image = Image(cell * columns, cell * rows, (0, 0, 0, 255))
    for y in range(image.height):
        for x in range(image.width):
            image.set(x, y, opaque(SATURATED[(x // cell + 2 * (y // cell)) % len(SATURATED)]))
    return image


def draw(number, image, origin_x, origin_y, width, height, scale, inset=0):
    columns = range(origin_x + inset, max(origin_x + inset, origin_x + width - inset))
    rows = range(origin_y + inset, max(origin_y + inset, origin_y + height - inset))
    digits = [int(c) for c in str(abs(number))]
    text_width = (len(digits) * 4 - 1) * scale
    # Swift's `/` truncates toward zero; the operands here are never negative.
    left = origin_x + int((width - text_width) / 2)
    top = origin_y + int((height - 5 * scale) / 2)
    for position, digit in enumerate(digits):
        for row in range(5):
            for column in range(3):
                if GLYPHS[digit][row] & (0b100 >> column) == 0:
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        x = left + (position * 4 + column) * scale + dx
                        y = top + row * scale + dy
                        if x in columns and y in rows:
                            image.set(x, y, (255, 255, 255, 255))


def covers(projection, x, y):
    w, h = PROJECTIONS[projection]
    if not (0 <= x < w and 0 <= y < h):
        return False
    if projection == "orthogonal":
        return True
    return abs(2 * x + 1 - w) * h + abs(2 * y + 1 - h) * w <= w * h


def numbered_tile(number, projection):
    w, h = PROJECTIONS[projection]
    image = Image(w, h, (0, 0, 0, 0))
    ground = opaque(MUTED[abs(number) % len(MUTED)])
    for y in range(h):
        for x in range(w):
            if covers(projection, x, y):
                image.set(x, y, ground)
    draw(number, image, 0, 0, w, h, 2)
    return image


def shifted_right(image):
    """`image` moved one pixel to the right, its first column repeated: a sub-pixel pan's worst whole step."""
    out = Image(image.width, image.height, (0, 0, 0, 0))
    for y in range(image.height):
        for x in range(image.width):
            out.set(x, y, image.pixels[y * image.width + max(0, x - 1)])
    return out


def pixels_per_degree(distance_metres, pixels_per_metre):
    return distance_metres * pixels_per_metre * math.pi / 180


# (name, actual, expected): the same pairs, in the same order, as the Swift test.
PAIRS = [
    ("digits", numbered_tile(7, "orthogonal"), numbered_tile(1, "orthogonal")),
    ("tiles", numbered_tile(1, "diamond48x28"), numbered_tile(0, "diamond48x28")),
    ("ramp-grid", saturated_neighbours(8, 8, 8), colour_ramp(64, 64)),
    ("ramp-shift", shifted_right(colour_ramp(64, 64)), colour_ramp(64, 64)),
]
CONDITIONS = [
    ("paper monitor", pixels_per_degree(0.7, 3840 / 0.7)),
    ("326 ppi at 0.3 m", pixels_per_degree(0.3, 326 / 0.0254)),
    ("460 ppi at 0.3 m", pixels_per_degree(0.3, 460 / 0.0254)),
]


def main():
    import numpy as np
    import flip_evaluator
    from importlib.metadata import version

    def array(image):
        rgb = np.array([p[:3] for p in image.pixels], dtype=np.float32) / 255
        return rgb.reshape(image.height, image.width, 3)

    print("flip-evaluator", version("flip-evaluator"))
    for name, actual, expected in PAIRS:
        print(name, "actual", actual.sha256(), "expected", expected.sha256())
    for label, ppd in CONDITIONS:
        for name, actual, expected in PAIRS:
            flip_map, mean, _ = flip_evaluator.evaluate(
                array(expected), array(actual), "LDR", inputsRGB=True, applyMagma=False, computeMeanError=True,
                parameters={"ppd": ppd})
            values = np.sort(np.asarray(flip_map, dtype=np.float64).reshape(-1))
            rank = (values.size * 99 + 99) // 100
            print("%-16s %.6f %-10s mean %.6f p99 %.6f" % (label, ppd, name, float(mean), values[max(0, rank - 1)]))


if __name__ == "__main__":
    main()
