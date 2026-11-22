"""Optional Google Cloud Vision OCR proxy for SHEET MASTER.

Not deployed or enabled by default. Requires Firebase App Check integration
in the iOS app, a configured Google Cloud project, and IAM credentials.
"""
import os

import firebase_admin
from firebase_admin import app_check
from flask import Flask, jsonify, request
from google.cloud import vision

app = Flask(__name__)
firebase_admin.initialize_app()
_client = vision.ImageAnnotatorClient()
MAX_IMAGE_BYTES = 8 * 1024 * 1024

@app.post("/v1/ocr")
def recognize_drawing():
    token = request.headers.get("X-Firebase-AppCheck", "")
    if not token:
        return jsonify(error="App Check token required"), 401
    try:
        app_check.verify_token(token)
    except Exception:
        return jsonify(error="Invalid App Check token"), 401

    if request.content_type not in ("image/jpeg", "image/png"):
        return jsonify(error="JPEG or PNG required"), 415
    if request.content_length is None or request.content_length > MAX_IMAGE_BYTES:
        return jsonify(error="Image too large"), 413
    raw = request.get_data(cache=False)
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        return jsonify(error="Image too large or empty"), 413

    result = _client.document_text_detection(
        image=vision.Image(content=raw),
        image_context=vision.ImageContext(language_hints=["ja", "en"]),
    )
    if result.error.message:
        app.logger.error("Google Vision OCR failed: %s", result.error.message)
        return jsonify(error="OCR request failed"), 502

    words = []
    for page in result.full_text_annotation.pages:
        width, height = max(1, page.width), max(1, page.height)
        for block in page.blocks:
            for paragraph in block.paragraphs:
                for word in paragraph.words:
                    value = "".join(s.text for s in word.symbols)
                    vertices = word.bounding_box.vertices
                    xs = [v.x / width for v in vertices]
                    ys = [v.y / height for v in vertices]
                    if value and xs and ys:
                        words.append({
                            "text": value,
                            "confidence": round(word.confidence, 4),
                            "box": [max(0.0, min(xs)), max(0.0, min(ys)),
                                    min(1.0, max(xs)), min(1.0, max(ys))],
                        })
    # Raw images, user identifiers and recognized drawing text are not logged.
    return jsonify(words=words)
