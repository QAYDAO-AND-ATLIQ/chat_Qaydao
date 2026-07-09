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
STATUS_LABELS = {"new": "جديد", "will": "سيتم الإرجاع", "doing": "جاري الإرجاع", "done": "تم الإرجاع", "rejected": "مرفوض"}


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
    accountant_note: Optional[str] = None
    reject_reason: Optional[str] = None


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
        rows = await c.fetch("SELECT * FROM return_requests ORDER BY id DESC LIMIT 2000")
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
    if body.status not in ("will", "doing", "done", "rejected"):
        raise HTTPException(400, "invalid status")
    if body.status == "rejected" and not (body.reject_reason or "").strip():
        raise HTTPException(400, "سبب الرفض مطلوب عند اختيار مرفوض")
    p = await pool()
    async with p.acquire() as c:
        r = await c.fetchrow("SELECT status_history FROM return_requests WHERE id=$1", rid)
        if not r:
            raise HTTPException(404, "not found")
        hist = r["status_history"]
        if isinstance(hist, str):
            hist = json.loads(hist)
        hist = list(hist or [])
        entry = {
            "status": body.status,
            "label": STATUS_LABELS[body.status],
            "by": body.changed_by or "financial@qaydao.com",
            "at": datetime.now(timezone.utc).isoformat(),
        }
        if body.accountant_note is not None and body.accountant_note.strip():
            entry["note"] = body.accountant_note.strip()
        if body.status == "rejected":
            entry["reject_reason"] = body.reject_reason.strip()
        hist.append(entry)
        note_val = body.accountant_note.strip() if (body.accountant_note and body.accountant_note.strip()) else None
        reject_val = body.reject_reason.strip() if body.status == "rejected" else None
        out = await c.fetchrow(
            """UPDATE return_requests
                 SET status=$2, status_history=$3::jsonb,
                     accountant_note=COALESCE($4, accountant_note),
                     reject_reason=CASE WHEN $2='rejected' THEN $5 ELSE reject_reason END
               WHERE id=$1 RETURNING *""",
            rid, body.status, json.dumps(hist), note_val, reject_val,
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
.tabs{display:flex;gap:8px;flex-wrap:wrap;margin:18px 0 6px}
.tab{font-family:inherit;font-size:13px;font-weight:700;cursor:pointer;border:1px solid var(--line);background:#fff;color:var(--soft);border-radius:999px;padding:8px 16px;transition:.15s;display:flex;align-items:center;gap:7px}
.tab:hover{border-color:var(--brand);color:var(--brand)}
.tab.active{background:var(--brand);color:#fff;border-color:var(--brand)}
.tab .cnt{font-size:11px;font-weight:700;background:rgba(0,0,0,.12);border-radius:999px;padding:1px 7px;min-width:18px;text-align:center}
.tab.active .cnt{background:rgba(255,255,255,.28)}
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
.st.rejected{background:#fdeded;color:#c0392b}
.cbody{padding:14px 16px}
.rowf{display:flex;justify-content:space-between;gap:10px;padding:5px 0;font-size:13px;border-bottom:1px dashed #eef1f4}
.rowf:last-of-type{border-bottom:none}
.rowf .k{color:var(--soft);font-weight:500;flex:0 0 auto}
.rowf .v{font-weight:600;text-align:end}
.copyv{display:inline-flex;gap:6px;align-items:center}
.cbtn{background:var(--brandsoft);color:var(--brandink);border:1px solid #cfe3e1;border-radius:7px;padding:2px 8px;font-family:inherit;font-size:11px;font-weight:700;cursor:pointer}
.cbtn.ok{background:var(--oksoft);color:var(--ok);border-color:#bfe3cd}
.olink{color:var(--brand);font-weight:700;text-decoration:none;border-bottom:1px dashed var(--brand)}
.sbtns{display:grid;grid-template-columns:repeat(2,1fr);gap:7px;margin-top:12px}
.sbtn{font-family:inherit;font-size:12px;font-weight:700;cursor:pointer;border-radius:9px;padding:9px 4px;border:1.5px solid transparent;transition:.15s}
.sbtn.will{background:var(--ambersoft);color:var(--amber);border-color:#eddcae}
.sbtn.doing{background:var(--infosoft);color:var(--info);border-color:var(--infoline)}
.sbtn.done{background:var(--oksoft);color:var(--ok);border-color:#c5dddb}
.sbtn.rejected{background:#fdeded;color:#c0392b;border-color:#f3c6c1}
.sbtn:hover{transform:translateY(-1px)}
.sbtn.active{box-shadow:0 0 0 3px rgba(31,95,91,.14)}
.qd-note-in{width:100%;font-family:inherit;font-size:12.5px;color:#1f2b3a;background:#f8fafb;border:1px solid var(--line);border-radius:9px;padding:8px 10px;margin-top:10px;resize:vertical}
.qd-note-in:focus{outline:none;border-color:var(--brand);background:#fff}
.qd-note-lbl{font-size:11.5px;font-weight:600;color:var(--soft);margin-top:11px;margin-bottom:2px}
.qd-reject-wrap{display:none;margin-top:8px}
.qd-reject-wrap.show{display:block}
.qd-reject-wrap textarea{border-color:#f3c6c1;background:#fdeded}
.rejsend{flex:1;font-family:inherit;font-size:12.5px;font-weight:700;cursor:pointer;border-radius:9px;padding:9px 6px;border:none;background:#c0392b;color:#fff;transition:.15s}
.rejsend:hover{background:#a5301f}
.rejcancel{font-family:inherit;font-size:12.5px;font-weight:600;cursor:pointer;border-radius:9px;padding:9px 14px;border:1px solid var(--line);background:#f8fafb;color:var(--soft)}
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
  <div class="tabs" id="tabs">
    <button class="tab active" data-tab="active" onclick="setTab('active',this)">النشطة <span class="cnt" id="cnt-active">0</span></button>
    <button class="tab" data-tab="done" onclick="setTab('done',this)">تم الإرجاع <span class="cnt" id="cnt-done">0</span></button>
    <button class="tab" data-tab="rejected" onclick="setTab('rejected',this)">مرفوض <span class="cnt" id="cnt-rejected">0</span></button>
    <button class="tab" data-tab="all" onclick="setTab('all',this)">الكل <span class="cnt" id="cnt-all">0</span></button>
  </div>
  <div class="tools">
    <input id="fsearch" placeholder="بحث بالاسم أو رقم الطلب أو المحادثة…" oninput="render()">
    <span class="count" id="count"></span>
    <button class="refresh" onclick="load()">تحديث ⟳</button>
  </div>
  <div class="grid" id="grid"></div>
  <div class="empty" id="empty" style="display:none">لا توجد طلبات في هذا القسم.</div>
  <footer>QAYDAO · صفحة المحاسب · التخزين في خدمة مستقلة — لا يوجد ربط فعلي مع قاعدة بيانات Chatwoot أو سلة</footer>
</div>
<div class="toast" id="toast"></div>
<script>
var API="/returns/api/requests";
var DATA=[];
var SL={new:"جديد",will:"سيتم الإرجاع",doing:"جاري الإرجاع",done:"تم الإرجاع",rejected:"مرفوض"};
function esc(s){return (s==null?"":String(s)).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}
function toast(m){var t=document.getElementById("toast");t.textContent=m;t.classList.add("show");setTimeout(function(){t.classList.remove("show")},2200)}
function copy(v,btn){navigator.clipboard.writeText(v).then(function(){var o=btn.textContent;btn.textContent="تم ✓";btn.classList.add("ok");setTimeout(function(){btn.textContent=o;btn.classList.remove("ok")},1400)})}
function load(){fetch(API).then(function(r){return r.json()}).then(function(d){DATA=Array.isArray(d)?d:[];render()}).catch(function(){document.getElementById("live").textContent="● غير متصل";document.getElementById("live").style.color="#c0392b"})}
var CURTAB="active";
function setTab(t,btn){
  CURTAB=t;
  var tabs=document.querySelectorAll("#tabs .tab");
  for(var i=0;i<tabs.length;i++)tabs[i].classList.remove("active");
  if(btn)btn.classList.add("active");
  render();
}
function inTab(x){
  if(CURTAB==="all")return true;
  if(CURTAB==="active")return (x.status==="new"||x.status==="will"||x.status==="doing");
  return x.status===CURTAB; // done | rejected
}
function updateCounts(){
  var a=0,d=0,r=0;
  DATA.forEach(function(x){
    if(x.status==="done")d++;
    else if(x.status==="rejected")r++;
    else a++;
  });
  var set=function(id,n){var e=document.getElementById(id);if(e)e.textContent=n};
  set("cnt-active",a);set("cnt-done",d);set("cnt-rejected",r);set("cnt-all",DATA.length);
}
function render(){
  updateCounts();
  var q=document.getElementById("fsearch").value.trim().toLowerCase();
  var list=DATA.filter(function(x){
    if(!inTab(x))return false;
    if(q){var h=((x.customer_name||"")+" "+(x.order_number||"")+" "+(x.conversation_id||"")).toLowerCase();if(h.indexOf(q)<0)return false}
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
      '<div class="rowf"><span class="k">اسم العميل</span><span class="v">'+esc(x.customer_name||"—")+'</span></div>'+
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
      (x.reject_reason?('<div class="rowf"><span class="k" style="color:#c0392b">سبب الرفض</span><span class="v" style="color:#c0392b">'+esc(x.reject_reason)+'</span></div>'):'')+
      '<div class="qd-reject-wrap" id="rejw_'+x.id+'"><div class="qd-note-lbl" style="color:#c0392b">سبب الرفض (إلزامي)</div>'+
        '<textarea class="qd-note-in" id="rej_'+x.id+'" rows="2" placeholder="اكتب سبب الرفض…">'+esc(x.reject_reason||"")+'</textarea>'+
        '<div style="display:flex;gap:8px;margin-top:8px">'+
          '<button class="rejsend" onclick="confirmReject('+x.id+',this)">تأكيد الرفض وإرسال</button>'+
          '<button class="rejcancel" onclick="cancelReject('+x.id+')">إلغاء</button>'+
        '</div></div>'+
      '<div class="sbtns">'+
        '<button class="sbtn will'+(x.status==="will"?" active":"")+'" onclick="setStatus('+x.id+',\'will\',this)">سيتم الإرجاع</button>'+
        '<button class="sbtn doing'+(x.status==="doing"?" active":"")+'" onclick="setStatus('+x.id+',\'doing\',this)">جاري الإرجاع</button>'+
        '<button class="sbtn done'+(x.status==="done"?" active":"")+'" onclick="setStatus('+x.id+',\'done\',this)">تم الإرجاع</button>'+
        '<button class="sbtn rejected'+(x.status==="rejected"?" active":"")+'" onclick="rejectClick('+x.id+',this)">مرفوض</button>'+
      '</div>'+
      (histRows?'<div class="hist show">'+histRows+'</div>':'')+
    '</div></div>';
}
function orderClick(n){toast("رقم الطلب "+n+" — الربط مع سلة سيُفعّل لاحقاً.");return false}
function rejectClick(id,btn){
  var wrap=document.getElementById("rejw_"+id);
  var rej=document.getElementById("rej_"+id);
  if(wrap){wrap.classList.add("show");if(rej)rej.focus();}
  toast("اكتب سبب الرفض ثم اضغط \u0022تأكيد الرفض وإرسال\u0022.");
}
function cancelReject(id){
  var wrap=document.getElementById("rejw_"+id);
  if(wrap)wrap.classList.remove("show");
}
function confirmReject(id,btn){
  var rej=document.getElementById("rej_"+id);
  var reason=rej?rej.value.trim():"";
  if(!reason){if(rej)rej.focus();toast("سبب الرفض مطلوب قبل الإرسال.");return}
  setStatus(id,"rejected",btn,reason);
}
function setStatus(id,st,btn,rejectReason){
  btn.disabled=true;
  var payload={status:st,changed_by:"financial@qaydao.com"};
  if(st==="rejected")payload.reject_reason=rejectReason||"";
  fetch(API+"/"+id+"/status",{method:"PATCH",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})
    .then(function(r){if(!r.ok)return r.json().then(function(e){throw {msg:(e&&e.detail)||0}});return r.json()})
    .then(function(u){
      var msg;
      if(st==="done")msg="تم إتمام الإرجاع وتسجيل تاريخ ووقت العملية.";
      else if(st==="rejected")msg="تم رفض الطلب وتسجيل السبب. سيظهر التنبيه للموظف.";
      else msg="تم تحديث الحالة إلى: "+SL[st]+". المدة المتوقعة للتحويل من ٧ إلى ١٤ يوم.";
      toast(msg);
      var i=DATA.findIndex(function(d){return d.id===id});if(i>=0)DATA[i]=u;
      render();
    })
    .catch(function(e){toast((e&&e.msg)||"تعذّر تحديث الحالة، حاول مجدداً.");btn.disabled=false});
}
load();
setInterval(load,20000);
</script></body></html>"""


# ------------------- Team "submitted requests" page -------------------
# Option B: NO bank account / IBAN columns (reduce spread of banking data).

@app.get("/returns/api/team-requests")
async def team_requests():
    p = await pool()
    async with p.acquire() as c:
        rows = await c.fetch(
            """SELECT id, conversation_id, customer_name, order_number, reason,
                      status, accountant_note, reject_reason, assignee,
                      return_created_at, updated_at
                 FROM return_requests ORDER BY id DESC LIMIT 300"""
        )
    out = []
    for r in rows:
        d = dict(r)
        for k in ("return_created_at",):
            if d.get(k) is not None:
                d[k] = d[k].isoformat()
        if d.get("updated_at") is not None:
            d["updated_at"] = d["updated_at"].isoformat()
        d["status_label"] = STATUS_LABELS.get(d.get("status"), d.get("status"))
        out.append(d)
    return out


@app.get("/returns/team-requests", response_class=HTMLResponse)
async def team_page():
    return HTMLResponse(TEAM_HTML)


TEAM_HTML = r"""<!DOCTYPE html>
<html lang="ar" dir="rtl"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>الطلبات المرفوعة — المرجعات — QAYDAO</title>
<link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>
:root{--bg:#f4f6f8;--surface:#fff;--ink:#1f2b3a;--soft:#5a6b7d;--line:#e4e9ee;--brand:#1f5f5b;--brandsoft:#e8f1f0;--ok:#1f7a4d;--oksoft:#e6f4ec;--amber:#b5791d;--ambersoft:#fbf0d9;--info:#2c5a86;--infosoft:#eef4fb;--rej:#c0392b;--rejsoft:#fdeded}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Cairo,system-ui,sans-serif;background:var(--bg);color:var(--ink);line-height:1.6;padding-bottom:50px}
.ltr{direction:ltr;unicode-bidi:isolate;display:inline-block}
.wrap{max-width:1240px;margin:0 auto;padding:0 18px}
.topbar{background:#12403d;color:#fff;text-align:center;padding:8px;font-size:12.5px;font-weight:600}
header{background:var(--surface);border-bottom:1px solid var(--line);padding:18px 0}
.hrow{display:flex;align-items:center;gap:13px;flex-wrap:wrap}
.logo{width:42px;height:42px;border-radius:11px;background:var(--brand);color:#fff;display:grid;place-items:center;font-weight:800;font-size:18px}
h1{font-size:19px;font-weight:800}
header p{font-size:12.5px;color:var(--soft);margin-top:2px}
.tools{display:flex;gap:10px;align-items:center;margin:16px 0;flex-wrap:wrap}
.tools select,.tools input{font-family:inherit;font-size:13.5px;padding:8px 12px;border:1px solid var(--line);border-radius:10px;background:#fff}
.refresh{margin-inline-start:auto;background:var(--brand);color:#fff;border:none;border-radius:10px;padding:8px 15px;font-family:inherit;font-weight:700;font-size:13px;cursor:pointer}
.count{font-size:12.5px;color:var(--soft)}
.rejbar{background:var(--rejsoft);border:1px solid #f3c6c1;color:var(--rej);border-radius:12px;padding:12px 15px;margin-bottom:14px;font-size:13px;font-weight:600;display:none}
.rejbar.show{display:block}
.rejbar a{color:var(--rej);font-weight:800}
.tablewrap{background:var(--surface);border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:0 1px 2px rgba(31,43,58,.04),0 6px 20px rgba(31,43,58,.05)}
table{width:100%;border-collapse:collapse;font-size:12.5px}
th,td{padding:11px 12px;text-align:start;border-bottom:1px solid #eef1f4;vertical-align:top}
th{background:#f8fafb;font-weight:700;color:var(--soft);white-space:nowrap;font-size:12px}
tr:last-child td{border-bottom:none}
tr.rejrow{background:var(--rejsoft)}
.badge{font-size:11px;font-weight:700;padding:3px 9px;border-radius:999px;white-space:nowrap}
.b-new{background:#eef1f4;color:#5a6b7d}.b-will{background:var(--ambersoft);color:var(--amber)}
.b-doing{background:var(--infosoft);color:var(--info)}.b-done{background:var(--oksoft);color:var(--ok)}
.b-rejected{background:var(--rejsoft);color:var(--rej)}
.note{color:var(--ink)}.rej{color:var(--rej);font-weight:700}
.empty{text-align:center;color:var(--soft);padding:50px 20px;font-size:15px;display:none}
footer{text-align:center;margin-top:22px;font-size:11.5px;color:var(--soft)}
@media(max-width:720px){th:nth-child(3),td:nth-child(3){display:none}}
</style></head><body>
<div class="topbar">📋 الطلبات المرفوعة — متابعة ردّ المحاسب على طلبات الإرجاع</div>
<header><div class="wrap hrow">
  <div class="logo">Q</div>
  <div><h1>الطلبات المرفوعة للمحاسب</h1><p>تابع حالة كل طلب إرجاع رفعته للمحاسب وردّه عليه — للرد على العميل.</p></div>
</div></header>
<div class="wrap">
  <div id="rejbar" class="rejbar"></div>
  <div class="tools">
    <select id="fstatus" onchange="render()">
      <option value="">كل الحالات</option>
      <option value="new">جديد</option><option value="will">سيتم الإرجاع</option>
      <option value="doing">جاري الإرجاع</option><option value="done">تم الإرجاع</option>
      <option value="rejected">مرفوض</option>
    </select>
    <input id="fsearch" placeholder="بحث بالاسم أو رقم المحادثة أو الطلب…" oninput="render()">
    <span class="count" id="count"></span>
    <button class="refresh" onclick="load()">تحديث ⟳</button>
  </div>
  <div class="tablewrap">
    <table>
      <thead><tr>
        <th>رقم المحادثة</th><th>العميل</th><th>رقم الطلب</th><th>سبب الإرجاع</th>
        <th>الحالة</th><th>ملاحظة المحاسب</th><th>سبب الرفض</th><th>الموظف</th>
      </tr></thead>
      <tbody id="tbody"></tbody>
    </table>
  </div>
  <div class="empty" id="empty">لا توجد طلبات مرفوعة بعد.</div>
  <footer>QAYDAO · الطلبات المرفوعة · البيانات البنكية غير معروضة هنا لدواعي الخصوصية — تظهر في نموذج الإدخال فقط</footer>
</div>
<script>
var API="/returns/api/team-requests";
var EMAIL="financial@qaydao.com";
var DATA=[];
var SL={new:"جديد",will:"سيتم الإرجاع",doing:"جاري الإرجاع",done:"تم الإرجاع",rejected:"مرفوض"};
function esc(s){return (s==null?"":String(s)).replace(/[&<>"]/g,function(c){return{"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}
function load(){fetch(API).then(function(r){return r.json()}).then(function(d){DATA=Array.isArray(d)?d:[];render()}).catch(function(){})}
function render(){
  var st=document.getElementById("fstatus").value;
  var q=document.getElementById("fsearch").value.trim().toLowerCase();
  var list=DATA.filter(function(x){
    if(st&&x.status!==st)return false;
    if(q){var h=((x.customer_name||"")+" "+(x.conversation_id||"")+" "+(x.order_number||"")).toLowerCase();if(h.indexOf(q)<0)return false}
    return true;
  });
  document.getElementById("count").textContent=list.length+" طلب";
  var rejected=list.filter(function(x){return x.status==="rejected"});
  var rb=document.getElementById("rejbar");
  if(rejected.length){rb.classList.add("show");rb.innerHTML="\u26A0 يوجد "+rejected.length+" طلب مرفوض. لمعرفة تفاصيل سبب الرفض تواصل مع المحاسب عبر الإيميل: <a href=\"mailto:"+EMAIL+"\">"+EMAIL+"</a>"}
  else{rb.classList.remove("show");rb.innerHTML=""}
  var tb=document.getElementById("tbody"),e=document.getElementById("empty");
  if(!list.length){tb.innerHTML="";e.style.display="block";return}
  e.style.display="none";
  tb.innerHTML=list.map(row).join("");
}
function row(x){
  var rej=x.status==="rejected";
  return '<tr class="'+(rej?"rejrow":"")+'">'+
    '<td class="ltr">'+esc(x.conversation_id||"—")+'</td>'+
    '<td>'+esc(x.customer_name||"—")+'</td>'+
    '<td class="ltr">'+esc(x.order_number||"—")+'</td>'+
    '<td>'+esc(x.reason||"—")+'</td>'+
    '<td><span class="badge b-'+esc(x.status)+'">'+esc(SL[x.status]||x.status)+'</span></td>'+
    '<td class="note">'+esc(x.accountant_note||"—")+'</td>'+
    '<td class="'+(rej?"rej":"")+'">'+(rej?(esc(x.reject_reason||"—")+'<br><span style="font-size:11px">\u26A0 تواصل مع المحاسب بالإيميل</span>'):'—')+'</td>'+
    '<td>'+esc(x.assignee||"—")+'</td>'+
  '</tr>';
}
load();
setInterval(load,20000);
</script></body></html>"""
