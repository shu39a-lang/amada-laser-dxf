import http from 'node:http';
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';

initializeApp({ credential: applicationDefault(), projectId: process.env.GOOGLE_CLOUD_PROJECT || 'sheet-master-e2aa0' });
const port = Number(process.env.PORT || 8080);
const maxBytes = 8 * 1024 * 1024;
const model = process.env.CLAUDE_MODEL || 'claude-sonnet-5-5';
const expectedAppId = process.env.FIREBASE_APP_ID;
if (!expectedAppId) throw new Error('FIREBASE_APP_ID must be configured');
const json = (res, status, obj) => {
  res.writeHead(status, { 'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store' });
  res.end(JSON.stringify(obj));
};
const readBody = async req => {
  let bytes = 0, chunks=[];
  for await (const c of req) {
    bytes += c.length;
    if (bytes > maxBytes) throw new Error('IMAGE_TOO_LARGE');
    chunks.push(c);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
};
http.createServer(async (req,res) => {
  if (req.method === 'GET' && req.url === '/health') return json(res,200,{ok:true,service:'sheet-master-claude-relay'});
  if (req.method !== 'POST' || req.url !== '/v1/analyze') return json(res,404,{error:'not_found'});
  const key=process.env.ANTHROPIC_API_KEY;
  if (!key) return json(res,503,{error:'server_not_configured'});
  const token=req.headers['x-firebase-appcheck'];
  if (typeof token !== 'string' || !token) return json(res,401,{error:'app_check_required'});
  try {
    const decoded=await getAppCheck().verifyToken(token);
    if (decoded.app_id !== expectedAppId) {
      return json(res,403,{error:'wrong_app'});
    }
  } catch {
    return json(res,401,{error:'invalid_app_check'});
  }
  let payload;
  try { payload=await readBody(req); } catch { return json(res,400,{error:'invalid_payload_or_image_too_large'}); }
  if (typeof payload?.imageBase64!=='string' || !/^[A-Za-z0-9+/=]+$/.test(payload.imageBase64) || 
      payload.imageBase64.length > 7_500_000 || typeof payload.prompt!=='string' || payload.prompt.length > 15000) {
    return json(res,400,{error:'invalid_image_or_prompt'});
  }
  const imageBytes=Buffer.from(payload.imageBase64,'base64');
  if (imageBytes.length < 100 || imageBytes.length > 5_000_000) return json(res,400,{error:'invalid_image_size'});
  const mediaType=imageBytes[0]===0xff&&imageBytes[1]===0xd8?'image/jpeg':
    imageBytes[0]===0x89&&imageBytes[1]===0x50?'image/png':null;
  if(!mediaType)return json(res,400,{error:'unsupported_image'});
  const abort=AbortSignal.timeout(100000);
  try {
    const upstream=await fetch('https://api.anthropic.com/v1/messages',{
      method:'POST', signal:abort,
      headers:{'x-api-key':key,'anthropic-version':'2023-06-01','content-type':'application/json'},
      body:JSON.stringify({model,max_tokens:4096,messages:[{role:'user',content:[
        {type:'image',source:{type:'base64',media_type:mediaType,data:payload.imageBase64}},
        {type:'text',text:payload.prompt+'\nReturn only one valid JSON object.'}
      ]}]})
    });
    if(!upstream.ok){
      // Do not echo sensitive upstream response or credentials.
      return json(res,502,{error:'claude_request_failed',upstream_status:upstream.status});
    }
    const result=await upstream.json();
    const text=(result.content||[]).filter(x=>x.type==='text').map(x=>x.text).join('\n');
    const start=text.indexOf('{'),end=text.lastIndexOf('}');
    if(start<0||end<start)return json(res,502,{error:'claude_non_json_response'});
    const parsed=JSON.parse(text.slice(start,end+1));
    if(!parsed || typeof parsed!=='object' || !Array.isArray(parsed.holes))return json(res,502,{error:'invalid_drawing_response'});
    return json(res,200,parsed);
  }catch {
    return json(res,502,{error:'claude_timeout_or_invalid_response'});
  }
}).listen(port,'0.0.0.0');
