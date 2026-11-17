import io
import time
import base64
import logging
from typing import Optional, List, Dict, Any

from fastapi import FastAPI, UploadFile, File, Form, Request, HTTPException
from fastapi.responses import JSONResponse
from PIL import Image
import numpy as np

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ocr-service")

app = FastAPI(
    title="WeKnora OCR & Layout Parsing Service",
    description="High-performance OCR service implementing PaddleOCR-VL protocol for WeKnora",
    version="1.0.0"
)

# Global engine instance
ocr_engine = None

def get_ocr():
    global ocr_engine
    if ocr_engine is None:
        logger.info("Initializing RapidOCR engine (ONNXRuntime, CPU)...")
        try:
            from rapidocr_onnxruntime import RapidOCR
            ocr_engine = RapidOCR()
            logger.info("RapidOCR engine initialized successfully.")
        except Exception as e:
            logger.error(f"Failed to initialize RapidOCR: {e}", exc_info=True)
            raise
    return ocr_engine

@app.on_event("startup")
async def startup_event():
    try:
        get_ocr()
    except Exception as e:
        logger.warning(f"Startup warm-up failed, will retry on first request: {e}")

@app.get("/health")
@app.get("/")
async def health_check():
    return {"status": "ok", "service": "ocr", "timestamp": int(time.time())}

# WeKnora PingPaddleOCRVL probes GET /layout-parsing
@app.get("/layout-parsing")
async def layout_parsing_ping():
    return {"status": "ok", "message": "PaddleOCR-VL endpoint ready"}

def run_ocr_on_image(img: Image.Image) -> Dict[str, Any]:
    """Run OCR on PIL Image and return lines, bboxes and dimensions."""
    engine = get_ocr()
    width, height = img.size
    img_np = np.array(img.convert("RGB"))

    result, _ = engine(img_np)

    parsing_res_list = []
    text_lines = []

    if result:
        for item in result:
            if not item or len(item) < 2:
                continue
            box = item[0]  # [[x1, y1], [x2, y2], [x3, y3], [x4, y4]]
            text = str(item[1])
            score = float(item[2]) if len(item) > 2 else 1.0

            xs = [pt[0] for pt in box]
            ys = [pt[1] for pt in box]
            min_x, max_x = min(xs), max(xs)
            min_y, max_y = min(ys), max(ys)

            parsing_res_list.append({
                "block_content": text,
                "block_bbox": [float(min_x), float(min_y), float(max_x), float(max_y)],
                "confidence": score
            })
            text_lines.append(text)

    markdown_text = "\n\n".join(text_lines)
    return {
        "width": width,
        "height": height,
        "markdown_text": markdown_text,
        "parsing_res_list": parsing_res_list
    }

@app.post("/layout-parsing")
async def layout_parsing(req: Request):
    """
    Implements WeKnora PaddleOCRVLReader endpoint format.
    Expects JSON { "file": "<base64>", "fileType": 0|1 }
    Returns { errorCode: 0, errorMsg: "", result: { layoutParsingResults: [...] } }
    """
    t0 = time.time()
    try:
        body = await req.json()
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")

    file_b64 = body.get("file", "")
    file_type = body.get("fileType", 1)  # 0 = PDF, 1 = image

    if not file_b64:
        raise HTTPException(status_code=400, detail="Missing file in base64 format")

    if "," in file_b64 and file_b64.startswith("data:"):
        file_b64 = file_b64.split(",", 1)[1]

    try:
        file_bytes = base64.b64decode(file_b64)
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Base64 decode failed: {e}")

    layout_results = []

    if file_type == 0:  # PDF
        try:
            import pypdfium2 as pdfium
            pdf = pdfium.PdfDocument(file_bytes)
            for page_idx in range(len(pdf)):
                page = pdf[page_idx]
                pil_image = page.render(scale=2.0).to_pil()
                ocr_data = run_ocr_on_image(pil_image)
                layout_results.append({
                    "markdown": {
                        "text": ocr_data["markdown_text"],
                        "images": {}
                    },
                    "prunedResult": {
                        "width": ocr_data["width"],
                        "height": ocr_data["height"],
                        "parsing_res_list": ocr_data["parsing_res_list"]
                    }
                })
        except Exception as e:
            logger.error(f"PDF parsing error: {e}", exc_info=True)
            return JSONResponse(status_code=500, content={"errorCode": 500, "errorMsg": f"PDF parsing failed: {e}"})
    else:  # Image
        try:
            pil_image = Image.open(io.BytesIO(file_bytes))
            ocr_data = run_ocr_on_image(pil_image)
            layout_results.append({
                "markdown": {
                    "text": ocr_data["markdown_text"],
                    "images": {}
                },
                "prunedResult": {
                    "width": ocr_data["width"],
                    "height": ocr_data["height"],
                    "parsing_res_list": ocr_data["parsing_res_list"]
                }
            })
        except Exception as e:
            logger.error(f"Image parsing error: {e}", exc_info=True)
            return JSONResponse(status_code=500, content={"errorCode": 500, "errorMsg": f"Image parsing failed: {e}"})

    duration_ms = int((time.time() - t0) * 1000)
    logger.info(f"Processed layout-parsing (type={file_type}, pages={len(layout_results)}) in {duration_ms}ms")

    return {
        "errorCode": 0,
        "errorMsg": "",
        "result": {
            "layoutParsingResults": layout_results
        }
    }

@app.post("/ocr")
@app.post("/predict")
async def generic_ocr(
    request: Request,
    file: Optional[UploadFile] = File(None),
    image_base64: Optional[str] = Form(None)
):
    """Standard OCR API for general applications."""
    t0 = time.time()
    img_bytes = None

    if file is not None:
        img_bytes = await file.read()
    elif image_base64:
        if "," in image_base64 and image_base64.startswith("data:"):
            image_base64 = image_base64.split(",", 1)[1]
        img_bytes = base64.b64decode(image_base64)
    else:
        try:
            json_data = await request.json()
            b64 = json_data.get("image") or json_data.get("file")
            if b64:
                if "," in b64 and b64.startswith("data:"):
                    b64 = b64.split(",", 1)[1]
                img_bytes = base64.b64decode(b64)
        except Exception:
            pass

    if not img_bytes:
        raise HTTPException(status_code=400, detail="No image provided")

    try:
        pil_image = Image.open(io.BytesIO(img_bytes))
        ocr_data = run_ocr_on_image(pil_image)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"OCR execution failed: {e}")

    duration_ms = int((time.time() - t0) * 1000)
    return {
        "success": True,
        "results": ocr_data["parsing_res_list"],
        "text": ocr_data["markdown_text"],
        "width": ocr_data["width"],
        "height": ocr_data["height"],
        "processing_time_ms": duration_ms
    }
