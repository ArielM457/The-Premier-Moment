"""Huella visual compartida por el generador y el servicio de reproducción."""

from __future__ import annotations

from base64 import b64decode, b64encode
from io import BytesIO

import numpy as np
from PIL import Image, ImageOps

FINGERPRINT_WIDTH = 32
FINGERPRINT_HEIGHT = 18
FINGERPRINT_CHANNELS = 3
FINGERPRINT_SIZE = FINGERPRINT_WIDTH * FINGERPRINT_HEIGHT * FINGERPRINT_CHANNELS
# Un fotograma de vídeo no pasa de 4K. Una imagen pequeña en bytes puede declarar
# dimensiones enormes y agotar la memoria al decodificarse: se rechaza antes.
MAX_SOURCE_PIXELS = 3840 * 2160


def image_fingerprint(content: bytes) -> bytes:
    """Normaliza una imagen a una miniatura RGB estable frente a JPEG."""
    with Image.open(BytesIO(content)) as source:
        width, height = source.size
        if width * height > MAX_SOURCE_PIXELS:
            raise ValueError("La imagen supera el tamaño de un fotograma de vídeo")
        image = ImageOps.exif_transpose(source).convert("RGB")
        image = image.resize(
            (FINGERPRINT_WIDTH, FINGERPRINT_HEIGHT),
            Image.Resampling.LANCZOS,
        )
        return image.tobytes()


def fingerprint_array(content: bytes) -> np.ndarray:
    return np.frombuffer(image_fingerprint(content), dtype=np.uint8).reshape(
        FINGERPRINT_HEIGHT,
        FINGERPRINT_WIDTH,
        FINGERPRINT_CHANNELS,
    )


def encode_fingerprint(content: bytes) -> str:
    return b64encode(image_fingerprint(content)).decode("ascii")


def decode_fingerprint(encoded: str) -> np.ndarray:
    raw = b64decode(encoded, validate=True)
    if len(raw) != FINGERPRINT_SIZE:
        raise ValueError("La huella visual no tiene el tamaño esperado")
    return np.frombuffer(raw, dtype=np.uint8).reshape(
        FINGERPRINT_HEIGHT,
        FINGERPRINT_WIDTH,
        FINGERPRINT_CHANNELS,
    )


def normalized_features(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Devuelve color y luminancia normalizada para comparar fotogramas."""
    color = rgb.astype(np.float32) / 255.0
    gray = (
        color[:, :, 0] * 0.299
        + color[:, :, 1] * 0.587
        + color[:, :, 2] * 0.114
    )
    gray = (gray - gray.mean()) / max(float(gray.std()), 1e-6)
    return color.reshape(-1), gray.reshape(-1)


def visual_scores(query: np.ndarray, references: list[np.ndarray]) -> np.ndarray:
    """Puntaje bajo significa mayor semejanza visual."""
    if not references:
        return np.empty(0, dtype=np.float32)
    query_color, query_gray = normalized_features(query)
    reference_color = []
    reference_gray = []
    for item in references:
        color, gray = normalized_features(item)
        reference_color.append(color)
        reference_gray.append(gray)
    color_matrix = np.stack(reference_color)
    gray_matrix = np.stack(reference_gray)
    color_mse = np.mean((color_matrix - query_color) ** 2, axis=1)
    gray_mse = np.mean((gray_matrix - query_gray) ** 2, axis=1)
    return color_mse * 0.35 + gray_mse * 0.65
