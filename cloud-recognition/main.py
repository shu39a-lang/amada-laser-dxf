"""SHEET MASTER Cloud Run backend. Returns unverified drawing measurements only."""
import base64
import json
import os
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
app = FastAPI(docs_url=None, redoc_url=None)
class Request(BaseModel):
    image_base64: str = Field(min_length=100, max_length=12000000)
    mime_type: str
PROMPT = """Read this manufacturing drawing and return only JSON with fields:
width, height, thickness, chamfer (numbers or null, millimeters);
material and drawing_number (strings or null);
holes (array of {x,y,diameter}, each number or null);
warnings (array of strings).
Only use explicitly printed dimensions and dimension callouts.
Never estimate from pixels, assume an unmarked origin, or fabricate a number.
Use bottom-left origin only if explicitly established in the drawing.
If uncertain, return null and explain in warnings.
Do not output G-code, NC code, or manufacturing instructions.
Maximum 150 holes. Human verification is required."""
def number(v):
    if isinstance(v, bool) or not isinstance(v, (int,float)): return None
    f = float(v)
    return f if f == f and 0 <= f <= 100000 else None
def normalize(data):
    if not isinstance(data, dict): raise ValueError("Invalid AI object")
    fields = {k:number(data.get(k)) for k in ("width","height","thickness","chamfer")}
    for k in ("width","height","thickness"):
        if fields[k] == 0: fields[k] = None
    holes = data.get("holes",[])
    if not isinstance(holes,list) or len(holes)>150: raise ValueError("Invalid hole count")
    warnings=data.get("warnings",[])
    if not isinstance(warnings,list): warnings=[]
    return {**fields,
      "material":str(data.get("material") or "")[:100],
      "drawing_number":str(data.get("drawing_number") or "")[:100],
      "holes":[{k:number(h.get(k)) for k in ("x","y","diameter")} for h in holes if isinstance(h,dict)],
      "warnings":[str(w)[:300] for w in warnings[:30]],
      "verified":False}
def verify_app_check(token):
    if not token: raise HTTPException(401,"Firebase App Check required")
    try:
        from firebase_admin import app_check, get_app, initialize_app
        try: get_app()
        except ValueError: initialize_app()
        app_check.verify_token(token)
    except Exception:
        raise HTTPException(401,"Invalid App Check token") from None
@app.post("/recognize")
def recognize(req: Request, x_firebase_appcheck: str | None = Header(default=None)):
    verify_app_check(x_firebase_appcheck)
    if req.mime_type not in ("image/jpeg","image/png"):
        raise HTTPException(415,"JPEG or PNG required")
    try: img=base64.b64decode(req.image_base64,validate=True)
    except Exception: raise HTTPException(400,"Invalid base64") from None
    if not img or len(img)>8*1024*1024: raise HTTPException(413,"Image size invalid")
    if req.mime_type=="image/jpeg" and not img.startswith(b"\xff\xd8\xff"):
        raise HTTPException(400,"Not a JPEG")
    if req.mime_type=="image/png" and not img.startswith(b"\x89PNG\r\n\x1a\n"):
        raise HTTPException(400,"Not a PNG")
    project=os.getenv("GOOGLE_CLOUD_PROJECT")
    if not project: raise HTTPException(503,"Project not configured")
    try:
        from google import genai
        from google.genai import types
        client=genai.Client(vertexai=True,project=project,location=os.getenv("VERTEX_REGION","global"))
        response=client.models.generate_content(
            model=os.getenv("GEMINI_MODEL","gemini-2.5-flash"),
            contents=[types.Part.from_bytes(data=img,mime_type=req.mime_type),PROMPT],
            config=types.GenerateContentConfig(response_mime_type="application/json",temperature=0))
        return normalize(json.loads(response.text))
    except ValueError:
        raise HTTPException(502,"Invalid AI result") from None
    except Exception:
        raise HTTPException(502,"Recognition unavailable") from None
@app.get("/health")
def health(): return {"status":"ready"}
