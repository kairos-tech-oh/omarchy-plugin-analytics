#!/usr/bin/env python3
# Header-parser and URL-normalisation assertions for the README image path.

import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("collect", os.path.join(HERE, "..", "helper", "collect.py"))
C = importlib.util.module_from_spec(spec)
spec.loader.exec_module(C)
FAILS = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + (("  " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def png(w, h):
    return b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" + struct.pack(">II", w, h) + b"\x08\x06\x00\x00\x00"


def jpeg(w, h):
    # SOI, APP0 stub, then SOF0 with height/width.
    return (b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
            + b"\xff\xc0\x00\x11\x08" + struct.pack(">HH", h, w) + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01")


def gif(w, h):
    return b"GIF89a" + struct.pack("<HH", w, h) + b"\xf7\x00\x00"


def webp_vp8x(w, h):
    return b"RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00" + (w - 1).to_bytes(3, "little") + (h - 1).to_bytes(3, "little")


def within(dims):
    fmt, w, h = dims
    return (1 <= w <= C.IMAGE_MAX_DIM and 1 <= h <= C.IMAGE_MAX_DIM) and w * h <= C.IMAGE_MAX_PIXELS


check("png dims", C.image_dimensions(png(2000, 1250)) == ("png", 2000, 1250))
check("jpeg dims via SOF", C.image_dimensions(jpeg(1280, 720)) == ("jpeg", 1280, 720))
check("gif dims", C.image_dimensions(gif(640, 360)) == ("gif", 640, 360))
check("webp VP8X dims", C.image_dimensions(webp_vp8x(1920, 1080)) == ("webp", 1920, 1080))
check("unknown format refused", C.image_dimensions(b"<svg xmlns='http://www.w3.org/2000/svg'>") is None)
check("png bomb refused (8000x8000)", not within(C.image_dimensions(png(8000, 8000))))
check("png 2^32-1 per side refused before multiplying", not within(C.image_dimensions(png(0xFFFFFFFF, 0xFFFFFFFF))))
check("png 4000x3000 allowed", within(C.image_dimensions(png(4000, 3000))))
check("png zero side refused", not within(C.image_dimensions(png(0, 100))))

n = C.normalize_image_url
check("relative path -> raw HEAD", n("docs/shot.png", "o", "r") == "https://raw.githubusercontent.com/o/r/HEAD/docs/shot.png")
check("./relative path -> raw HEAD", n("./preview.png", "o", "r") == "https://raw.githubusercontent.com/o/r/HEAD/preview.png")
check("blob URL -> raw", n("https://github.com/o/r/blob/main/a.png?raw=true", "o", "r") == "https://raw.githubusercontent.com/o/r/main/a.png")
check("raw URL kept", n("https://raw.githubusercontent.com/o/r/HEAD/a.png", "o", "r") == "https://raw.githubusercontent.com/o/r/HEAD/a.png")
check("http refused", n("http://example.com/a.png", "o", "r") is None)
check("control chars refused", n("https://x/a.png\r\nX: y", "o", "r") is None)
check("quote refused", n("https://x/a.png\"", "o", "r") is None)
check("external https passes normalisation (host check happens later)", n("https://img.shields.io/x.svg", "o", "r") == "https://img.shields.io/x.svg")

print()
if FAILS:
    print("%d FAILED: %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("all image checks passed")
