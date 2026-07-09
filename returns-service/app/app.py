"""
QAYDAO Returns Service — isolated sidecar.
- Stores return requests in its OWN postgres DB (`returns`), linked to Chatwoot conversation_id (loose ref).
- Never touches chatwoot_production or Chatwoot tables.
- Serves:
    GET  /returns/api/health
    GET  /returns/api/requests?conversation_id=..   -> latest request for a conversation (for the CS tab)
    GET  /returns/api/requests/{id}
    GET  /returns/api/requests                        -> list (accountant page)
    POST /returns/api/requests                        -> create/update from CS tab
    PATCH /returns/api/requests/{id}/status           -> accountant status change
    GET  /accountant-returns                          -> accountant read-only HTML page (nginx adds basic-auth)
Auth model: the CS tab is only reachable inside Chatwoot (post-login). The accountant page is protected
by nginx basic-auth in front of this service. This service trusts the reverse proxy.
"""
import os
import json
import uuid
import asyncpg
from pathlib import Path
from datetime import datetime, timezone
from fastapi import FastAPI, HTTPException, Request, UploadFile, File
from fastapi.responses import JSONResponse, HTMLResponse, Response, FileResponse
from pydantic import BaseModel
from typing import Optional

UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/data/uploads"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
MAX_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB
ALLOWED_MIME = {
    "application/pdf": ".pdf",
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}

DATABASE_URL = os.environ["DATABASE_URL"]
app = FastAPI(title="QAYDAO Returns Service")
_pool: Optional[asyncpg.Pool] = None

REASONS = [
    "المنتج تالف", "المنتج غير مطابق للوصف", "وصل منتج مختلف",
    "العميل غيّر رأيه", "تأخر التوصيل", "مشكلة في المقاس أو اللون",
    "نقص في الطلب", "سبب آخر",
]
ASSIGNEES = ["في", "مروة", "أميرة"]
STATUS_LABELS = {"new": "جديد", "will": "سيتم الإرجاع", "doing": "جاري الإرجاع", "done": "تم الإرجاع"}


async def pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(DATABASE_URL, min_size=1, max_size=5)
    return _pool


@app.on_event("startup")
async def _startup():
    # wait for DB (initdb may still be running)
    import asyncio
    for _ in range(30):
        try:
            p = await pool()
            async with p.acquire() as c:
                await c.execute("SELECT 1")
            return
        except Exception:
            await asyncio.sleep(1)


def row_to_dict(r) -> dict:
    d = dict(r)
    for k in ("created_at", "updated_at"):
        if d.get(k) is not None:
            d[k] = d[k].isoformat()
    for k in ("return_created_at", "original_order_at"):
        if d.get(k) is not None:
            d[k] = d[k].isoformat()
    if isinstance(d.get("status_history"), str):
        try:
            d["status_history"] = json.loads(d["status_history"])
        except Exception:
            d["status_history"] = []
    d["status_label"] = STATUS_LABELS.get(d.get("status"), d.get("status"))
    return d


class ReturnIn(BaseModel):
    conversation_id: Optional[int] = None
    customer_name: Optional[str] = None
    order_number: Optional[str] = None
    order_amount: Optional[str] = None
    return_created_at: Optional[str] = None
    original_order_at: Optional[str] = None
    reason: Optional[str] = None
    bank_name: Optional[str] = None
    bank_account: Optional[str] = None
    iban: Optional[str] = None
    attachment_name: Optional[str] = None
    assignee: Optional[str] = None
    created_by: Optional[str] = None


class StatusIn(BaseModel):
    status: str
    changed_by: Optional[str] = None


# ------------------------------- API -------------------------------

@app.get("/returns/api/health")
async def health():
    try:
        p = await pool()
        async with p.acquire() as c:
            await c.execute("SELECT 1")
        return {"ok": True}
    except Exception as e:
        raise HTTPException(500, f"db: {e}")


def _parse_date(v):
    if not v:
        return None
    try:
        return datetime.strptime(v[:10], "%Y-%m-%d").date()
    except Exception:
        return None


@app.post("/returns/api/requests")
async def create_or_update(body: ReturnIn):
    p = await pool()
    async with p.acquire() as c:
        existing = None
        if body.conversation_id is not None:
            existing = await c.fetchrow(
                "SELECT id FROM return_requests WHERE conversation_id=$1 ORDER BY id DESC LIMIT 1",
                body.conversation_id,
            )
        rc = _parse_date(body.return_created_at)
        oo = _parse_date(body.original_order_at)
        if existing:
            r = await c.fetchrow(
                """UPDATE return_requests SET
                     customer_name=$2, order_number=$3, order_amount=$4,
                     return_created_at=$5, original_order_at=$6, reason=$7,
                     bank_name=$8, bank_account=$9, iban=$10, attachment_name=$11,
                     assignee=$12, created_by=COALESCE($13, created_by)
                   WHERE id=$1 RETURNING *""",
                existing["id"], body.customer_name, body.order_number, body.order_amount,
                rc, oo, body.reason, body.bank_name, body.bank_account, body.iban,
                body.attachment_name, body.assignee, body.created_by,
            )
        else:
            r = await c.fetchrow(
                """INSERT INTO return_requests
                     (conversation_id, customer_name, order_number, order_amount,
                      return_created_at, original_order_at, reason, bank_name,
                      bank_account, iban, attachment_name, assignee, status, created_by)
                   VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,'new',$13)
                   RETURNING *""",
                body.conversation_id, body.customer_name, body.order_number, body.order_amount,
                rc, oo, body.reason, body.bank_name, body.bank_account, body.iban,
                body.attachment_name, body.assignee, body.created_by,
            )
        return row_to_dict(r)


@app.get("/returns/api/requests")
async def list_requests(conversation_id: Optional[int] = None):
    p = await pool()
    async with p.acquire() as c:
        if conversation_id is not None:
            r = await c.fetchrow(
                "SELECT * FROM return_requests WHERE conversation_id=$1 ORDER BY id DESC LIMIT 1",
                conversation_id,
            )
            return row_to_dict(r) if r else JSONResponse(None)
        rows = await c.fetch("SELECT * FROM return_requests ORDER BY id DESC LIMIT 200")
        return [row_to_dict(r) for r in rows]


@app.get("/returns/api/requests/{rid}")
async def get_request(rid: int):
    p = await pool()
    async with p.acquire() as c:
        r = await c.fetchrow("SELECT * FROM return_requests WHERE id=$1", rid)
    if not r:
        raise HTTPException(404, "not found")
    return row_to_dict(r)


@app.patch("/returns/api/requests/{rid}/status")
async def set_status(rid: int, body: StatusIn):
    if body.status not in ("will", "doing", "done"):
        raise HTTPException(400, "invalid status")
    p = await pool()
    async with p.acquire() as c:
        r = await c.fetchrow("SELECT status_history FROM return_requests WHERE id=$1", rid)
        if not r:
            raise HTTPException(404, "not found")
        hist = r["status_history"]
        if isinstance(hist, str):
            hist = json.loads(hist)
        hist = list(hist or [])
        hist.append({
            "status": body.status,
            "label": STATUS_LABELS[body.status],
            "by": body.changed_by or "financial@qaydao.com",
            "at": datetime.now(timezone.utc).isoformat(),
        })
        out = await c.fetchrow(
            "UPDATE return_requests SET status=$2, status_history=$3::jsonb WHERE id=$1 RETURNING *",
            rid, body.status, json.dumps(hist),
        )
    return row_to_dict(out)


# ------------------------- Accountant page -------------------------

@app.get("/accountant-returns", response_class=HTMLResponse)
async def accountant_page():
    return HTMLResponse(ACCOUNTANT_HTML)


@app.post("/returns/api/requests/{rid}/attachment")
async def upload_attachment(rid: int, file: UploadFile = File(...)):
    mime = (file.content_type or "").split(";")[0].strip().lower()
    if mime not in ALLOWED_MIME:
        raise HTTPException(400, "نوع ملف غير مسموح. المسموح: PDF, JPG, PNG, WEBP")
    data = await file.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(400, "حجم الملف يتجاوز 10 ميجابايت")
    if not data:
        raise HTTPException(400, "الملف فارغ")

    p = await pool()
    async with p.acquire() as c:
        exists = await c.fetchrow("SELECT attachment_path FROM return_requests WHERE id=$1", rid)
        if not exists:
            raise HTTPException(404, "not found")
        # remove previous file if present
        old = exists["attachment_path"]
        if old:
            try:
                Path(old).unlink(missing_ok=True)
            except Exception:
                pass
        ext = ALLOWED_MIME[mime]
        fname = f"{rid}_{uuid.uuid4().hex}{ext}"
        fpath = UPLOAD_DIR / fname
        fpath.write_bytes(data)
        orig = os.path.basename(file.filename or f"attachment{ext}")
        r = await c.fetchrow(
            """UPDATE return_requests
                 SET attachment_name=$2, attachment_path=$3, attachment_mime=$4
               WHERE id=$1 RETURNING *""",
            rid, orig, str(fpath), mime,
        )
    return row_to_dict(r)


@app.get("/returns/api/requests/{rid}/attachment")
async def download_attachment(rid: int):
    p = await pool()
    async with p.acquire() as c:
        r = await c.fetchrow(
            "SELECT attachment_name, attachment_path, attachment_mime FROM return_requests WHERE id=$1",
            rid,
        )
    if not r or not r["attachment_path"]:
        raise HTTPException(404, "لا يوجد ملف مرفق")
    fp = Path(r["attachment_path"])
    if not fp.exists():
        raise HTTPException(404, "الملف غير موجود على الخادم")
    return FileResponse(
        str(fp),
        media_type=r["attachment_mime"] or "application/octet-stream",
        filename=r["attachment_name"] or fp.name,
    )


@app.get("/returns/api/config")
async def config():
    return {"reasons": REASONS, "assignees": ASSIGNEES, "status_labels": STATUS_LABELS}


ACCOUNTANT_HTML = r"""<!DOCTYPE html>
<html lang="ar" dir="rtl"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>صفحة المحاسب — المرجعات — QAYDAO</title>
<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
:root{--bg:#f4f6f8;--surface:#fff;--ink:#1f2b3a;--soft:#5a6b7d;--line:#e4e9ee;--brand:#1f5f5b;--brandsoft:#e8f1f0;--brandink:#12403d;--accent:#c8892a;--ok:#1f7a4d;--oksoft:#e6f4ec;--amber:#b5791d;--ambersoft:#fbf0d9;--info:#2c5a86;--infosoft:#eef4fb;--infoline:#cfe0f2}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Cairo,system-ui,sans-serif;background:var(--bg);color:var(--ink);line-height:1.7;padding-bottom:50px}
.ltr{direction:ltr;unicode-bidi:isolate;display:inline-block}
.wrap{max-width:1200px;margin:0 auto;padding:0 20px}
.topbar{background:repeating-linear-gradient(-45deg,#12403d,#12403d 12px,#0f3a37 12px,#0f3a37 24px);color:#fff;text-align:center;padding:8px;font-size:12.5px;font-weight:600}
.topbar b{color:#ffd479}
header{background:var(--surface);border-bottom:1px solid var(--line);padding:20px 0}
.hrow{display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.logo{width:44px;height:44px;border-radius:11px;background:var(--brand);color:#fff;display:grid;place-items:center;font-weight:800;font-size:19px}
h1{font-size:20px;font-weight:800}
header p{font-size:13px;color:var(--soft);margin-top:2px}
.pill{margin-inline-start:auto;background:var(--oksoft);color:var(--ok);border:1px solid #bfe3cd;border-radius:999px;padding:6px 13px;font-size:12px;font-weight:700}
.tools{display:flex;gap:10px;align-items:center;margin:18px 0;flex-wrap:wrap}
.tools select,.tools input{font-family:inherit;font-size:13.5px;padding:9px 12px;border:1px solid var(--line);border-radius:10px;background:#fff}
.refresh{margin-inline-start:auto;background:var(--brand);color:#fff;border:none;border-radius:10px;padding:9px 16px;font-family:inherit;font-weight:700;font-size:13px;cursor:pointer}
.count{font-size:12.5px;color:var(--soft)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:16px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;box-shadow:0 1px 2px rgba(31,43,58,.04),0 6px 20px rgba(31,43,58,.05);overflow:hidden}
.chead{padding:14px 16px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:9px}
.chead .nm{font-weight:700;font-size:15px}
.chead .st{margin-inline-start:auto;font-size:11px;font-weight:700;padding:4px 10px;border-radius:999px}
.st.new{background:#eef1f4;color:#5a6b7d}
.st.will{background:var(--ambersoft);color:var(--amber)}
.st.doing{background:var(--infosoft);color:var(--info)}
.st.done{background:var(--oksoft);color:var(--ok)}
.cbody{padding:14px 16px}
.rowf{display:flex;justify-content:space-between;gap:10px;padding:5px 0;font-size:13px;border-bottom:1px dashed #eef1f4}
.rowf:last-of-type{border-bottom:none}
.rowf .k{color:var(--soft);font-weight:500;flex:0 0 auto}
.rowf .v{font-weight:600;text-align:end}
.copyv{display:inline-flex;gap:6px;align-items:center}
.cbtn{background:var(--brandsoft);color:var(--brandink);border:1px solid #cfe3e1;border-radius:7px;padding:2px 8px;font-family:inherit;font-size:11px;font-weight:700;cursor:pointer}
.cbtn.ok{background:var(--oksoft);color:var(--ok);border-color:#bfe3cd}
.olink{color:var(--brand);font-weight:700;text-decoration:none;border-bottom:1px dashed var(--brand)}
.sbtns{display:grid;grid-template-columns:repeat(3,1fr);gap:7px;margin-top:12px}
.sbtn{font-family:inherit;font-size:12px;font-weight:700;cursor:pointer;border-radius:9px;padding:9px 4px;border:1.5px solid transparent;transition:.15s}
.sbtn.will{background:var(--ambersoft);color:var(--amber);border-color:#eddcae}
.sbtn.doing{background:var(--infosoft);color:var(--info);border-color:var(--infoline)}
.sbtn.done{background:var(--oksoft);color:var(--ok);border-color:#c5dddb}
.sbtn:hover{transform:translateY(-1px)}
.sbtn.active{box-shadow:0 0 0 3px rgba(31,95,91,.14)}
.hist{margin-top:11px;font-size:11.5px;color:var(--soft);background:#f8fafb;border-radius:9px;padding:9px 11px;display:none}
.hist.show{display:block}
.hist b{color:var(--ink)}
.empty{text-align:center;color:var(--soft);padding:60px 20px;font-size:15px}
.toast{position:fixed;bottom:20px;inset-inline-start:20px;background:var(--ink);color:#fff;padding:12px 18px;border-radius:11px;font-size:13.5px;font-weight:600;opacity:0;transform:translateY(10px);transition:.25s;z-index:99;pointer-events:none}
.toast.show{opacity:1;transform:none}
footer{text-align:center;margin-top:26px;font-size:11.5px;color:var(--soft)}
</style></head><body>
<div class="topbar">💼 صفحة المحاسب — <b>قراءة فقط</b> — يُسمح فقط بتغيير حالة الإرجاع</div>
<header><div class="wrap hrow">
  <div class="logo">Q</div>
  <div><h1>إدارة المرجعات — المحاسبة</h1><p>عرض طلبات الإرجاع الواردة من خدمة العملاء وتحديث حالتها.</p></div>
  <span class="pill" id="live">● متصل</span>
</div></header>
<div class="wrap">
  <div class="tools">
    <select id="fstatus" onchange="render()">
      <option value="">كل الحالات</option>
      <option value="new">جديد</option>
      <option value="will">سيتم الإرجاع</option>
      <option value="doing">جاري الإرجاع</option>
      <option value="done">تم الإرجاع</option>
    </select>
    <input id="fsearch" placeholder="بحث بالاسم أو رقم الطلب…" oninput="render()">
    <span class="count" id="count"></span>
    <button class="refresh" onclick="load()">تحديث ⟳</button>
  </div>
  <div class="grid" id="grid"></div>
  <div class="empty" id="empty" style="display:none">لا توجد طلبات إرجاع بعد.</div>
  <footer>QAYDAO · صفحة المحاسب · التخزين في خدمة مستقلة — لا يوجد ربط فعلي مع قاعدة بيانات Chatwoot أو سلة</footer>
</div>
<div class="toast" id="toast"></div>
<script>
var API="/returns/api/requests";
var DATA=[];
var SL={new:"جديد",will:"سيتم الإرجاع",doing:"جاري الإرجاع",done:"تم الإرجاع"};
function esc(s){return (s==null?"":String(s)).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}
function toast(m){var t=document.getElementById("toast");t.textContent=m;t.classList.add("show");setTimeout(function(){t.classList.remove("show")},2200)}
function copy(v,btn){navigator.clipboard.writeText(v).then(function(){var o=btn.textContent;btn.textContent="تم ✓";btn.classList.add("ok");setTimeout(function(){btn.textContent=o;btn.classList.remove("ok")},1400)})}
function load(){fetch(API).then(function(r){return r.json()}).then(function(d){DATA=Array.isArray(d)?d:[];render()}).catch(function(){document.getElementById("live").textContent="● غير متصل";document.getElementById("live").style.color="#c0392b"})}
function render(){
  var st=document.getElementById("fstatus").value;
  var q=document.getElementById("fsearch").value.trim().toLowerCase();
  var list=DATA.filter(function(x){
    if(st&&x.status!==st)return false;
    if(q){var h=((x.customer_name||"")+" "+(x.order_number||"")).toLowerCase();if(h.indexOf(q)<0)return false}
    return true;
  });
  document.getElementById("count").textContent=list.length+" طلب";
  var g=document.getElementById("grid"),e=document.getElementById("empty");
  if(!list.length){g.innerHTML="";e.style.display="block";return}
  e.style.display="none";
  g.innerHTML=list.map(card).join("");
}
function card(x){
  var acc=esc(x.bank_account||"—"),iban=esc(x.iban||"—");
  var order=x.order_number?('<a class="olink ltr" href="#" onclick="return orderClick(\''+esc(x.order_number)+'\')">'+esc(x.order_number)+'</a>'):"—";
  var histRows=(x.status_history||[]).map(function(h){return '<div><b>'+esc(h.label)+'</b> · '+esc((h.at||"").replace("T"," ").slice(0,16))+' · '+esc(h.by||"")+'</div>'}).join("");
  return '<div class="card">'+
    '<div class="chead"><span class="nm">'+esc(x.customer_name||"—")+'</span><span class="st '+x.status+'">'+esc(SL[x.status]||x.status)+'</span></div>'+
    '<div class="cbody">'+
      '<div class="rowf"><span class="k">رقم الطلب</span><span class="v">'+order+'</span></div>'+
      '<div class="rowf"><span class="k">مبلغ الطلب</span><span class="v">'+esc(x.order_amount||"—")+'</span></div>'+
      '<div class="rowf"><span class="k">سبب الإرجاع</span><span class="v">'+esc(x.reason||"—")+'</span></div>'+
      '<div class="rowf"><span class="k">تاريخ طلب الإرجاع</span><span class="v ltr">'+esc(x.return_created_at||"—")+'</span></div>'+
      '<div class="rowf"><span class="k">تاريخ الطلب الأصلي</span><span class="v ltr">'+esc(x.original_order_at||"—")+'</span></div>'+
      '<div class="rowf"><span class="k">البنك</span><span class="v">'+esc(x.bank_name||"—")+'</span></div>'+
      '<div class="rowf"><span class="k">الحساب البنكي</span><span class="v copyv"><span class="ltr">'+acc+'</span><button class="cbtn" onclick="copy(\''+acc+'\',this)">نسخ</button></span></div>'+
      '<div class="rowf"><span class="k">الآيبان</span><span class="v copyv"><span class="ltr">'+iban+'</span><button class="cbtn" onclick="copy(\''+iban+'\',this)">نسخ</button></span></div>'+
      '<div class="rowf"><span class="k">الموظف المسؤول</span><span class="v">'+esc(x.assignee||"—")+'</span></div>'+
      '<div class="rowf"><span class="k">ملف الحساب البنكي</span><span class="v">'+
        (x.attachment_name?('<a class="olink" href="/returns/api/requests/'+x.id+'/attachment" target="_blank">\u2B07 '+esc(x.attachment_name)+'</a>'):'—')+
      '</span></div>'+
      '<div class="sbtns">'+
        '<button class="sbtn will'+(x.status==="will"?" active":"")+'" onclick="setStatus('+x.id+',\'will\',this)">سيتم الإرجاع</button>'+
        '<button class="sbtn doing'+(x.status==="doing"?" active":"")+'" onclick="setStatus('+x.id+',\'doing\',this)">جاري الإرجاع</button>'+
        '<button class="sbtn done'+(x.status==="done"?" active":"")+'" onclick="setStatus('+x.id+',\'done\',this)">تم الإرجاع</button>'+
      '</div>'+
      (histRows?'<div class="hist show">'+histRows+'</div>':'')+
    '</div></div>';
}
function orderClick(n){toast("رقم الطلب "+n+" — الربط مع سلة سيُفعّل لاحقاً.");return false}
function setStatus(id,st,btn){
  btn.disabled=true;
  fetch(API+"/"+id+"/status",{method:"PATCH",headers:{"Content-Type":"application/json"},body:JSON.stringify({status:st,changed_by:"financial@qaydao.com"})})
    .then(function(r){if(!r.ok)throw 0;return r.json()})
    .then(function(u){
      var msg=st==="done"?"تم إتمام الإرجاع وتسجيل تاريخ ووقت العملية.":"تم تحديث الحالة إلى: "+SL[st]+". المدة المتوقعة للتحويل من ٧ إلى ١٤ يوم.";
      toast(msg);
      var i=DATA.findIndex(function(d){return d.id===id});if(i>=0)DATA[i]=u;
      render();
    })
    .catch(function(){toast("تعذّر تحديث الحالة، حاول مجدداً.");btn.disabled=false});
}
load();
setInterval(load,20000);
</script></body></html>"""
