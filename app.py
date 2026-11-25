#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FitLife Hub - ứng dụng quản lý chuỗi phòng tập (Giai đoạn 2 - cài đặt ứng dụng, CSC12002, nhóm 2627.ADB.CLC14)

Web app Flask gọi trực tiếp các stored procedure của script 03.
Chức năng:
  - Tần suất cao : check-in, tra cứu hội viên, đặt/hủy lịch PT, lập hóa đơn + thanh toán
  - Tần suất thấp: thêm/sửa/khóa hội viên, điều chuyển nhân viên, cập nhật lương, tính hoa hồng
  - Thống kê     : doanh thu, lấp đầy, tồn kho, bán chạy, hiệu suất HLV, sắp hết hạn, hạng, so sánh chi nhánh

Chạy:
    pip install flask pyodbc
    python app.py                                   # localhost, Windows Authentication, http://127.0.0.1:5000
    python app.py --server "localhost\\SQLEXPRESS"
    python app.py --user sa --password "..."
"""
import argparse
import os
import re
from datetime import date, timedelta

import jinja2
from flask import Flask, flash, redirect, render_template, request, url_for

app = Flask(__name__)
app.secret_key = os.environ.get("FITLIFE_SECRET") or os.urandom(32)

CONFIG = {"server": os.environ.get("FITLIFE_SERVER", "localhost"), "database": "FitLifeHub",
          "user": None, "password": os.environ.get("FITLIFE_PWD"), "driver": None}


# ---------------------------------------------------------------------------
# Truy cập CSDL
# ---------------------------------------------------------------------------
def _conn_string():
    import pyodbc
    drv = CONFIG["driver"]
    if not drv:
        c = [d for d in pyodbc.drivers() if "SQL Server" in d]
        odbc = sorted([d for d in c if d.startswith("ODBC Driver")], reverse=True)
        drv = (odbc or c or [None])[0]
        if not drv:
            raise RuntimeError("Không tìm thấy ODBC driver cho SQL Server (cài ODBC Driver 17/18).")
    cs = f"DRIVER={{{drv}}};SERVER={CONFIG['server']};DATABASE={CONFIG['database']};TrustServerCertificate=yes;"
    cs += f"UID={CONFIG['user']};PWD={CONFIG['password']};" if CONFIG["user"] else "Trusted_Connection=yes;"
    return cs


def run_sql(sql, params=()):
    """Chạy một câu lệnh/batch, trả về danh sách tập kết quả: [{'cols': [...], 'rows': [[...], ...]}, ...]"""
    import pyodbc
    cn = pyodbc.connect(_conn_string(), autocommit=True)
    try:
        cur = cn.cursor()
        cur.execute(sql, *params)
        sets = []
        while True:
            if cur.description:
                sets.append({"cols": [d[0] for d in cur.description], "rows": [list(r) for r in cur.fetchall()]})
            if not cur.nextset():
                break
        return sets
    finally:
        cn.close()


def friendly_error(e):
    """Lấy phần thông báo tiếng Việt của SQL Server, bỏ tiền tố driver."""
    s = str(e)
    parts = re.findall(r"\[SQL Server\]([^\[]*)", s)
    msg = parts[-1] if parts else s
    msg = re.sub(r"\s*\(\d+\)\s*(\(SQL\w+\))?\W*$", "", msg.strip())
    return msg.strip() or s


def safe(sql, params=(), default=None):
    """Chạy truy vấn; lỗi thì flash thông báo và trả về default."""
    try:
        return run_sql(sql, params)
    except Exception as e:  # noqa: BLE001 - hiển thị thông báo cho người dùng
        flash(friendly_error(e), "err")
        return default if default is not None else []


def rs(sets, i=0):
    return sets[i] if sets and len(sets) > i else {"cols": [], "rows": []}


def col(rset, name):
    """Cột theo tên (rỗng nếu không có)."""
    if name not in rset["cols"]:
        return []
    k = rset["cols"].index(name)
    return [r[k] for r in rset["rows"]]


def fmt(v):
    if v is None:
        return ""
    if hasattr(v, "isoformat"):
        return v.isoformat(sep=" ") if hasattr(v, "hour") else v.isoformat()
    if isinstance(v, float):
        return f"{v:,.2f}"
    if isinstance(v, int) and not isinstance(v, bool) and abs(v) >= 10000:
        return f"{v:,}"
    try:
        from decimal import Decimal
        if isinstance(v, Decimal):
            return f"{v:,.0f}" if v == v.to_integral_value() else f"{v:,.2f}"
    except Exception:  # noqa: BLE001
        pass
    return str(v)


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


# ---------------------------------------------------------------------------
# Danh mục dùng cho form
# ---------------------------------------------------------------------------
def lk_chi_nhanh():
    return rs(safe("SELECT ma_cn, ten_cn FROM dbo.CHI_NHANH WHERE trang_thai='HOAT_DONG' ORDER BY ma_cn"))["rows"]


def lk_goi():
    return rs(safe("SELECT ma_goi, ten_goi, gia_tien FROM dbo.GOI_DICH_VU WHERE trang_thai_ban='DANG_BAN' ORDER BY ma_goi"))["rows"]


def lk_san_pham():
    return rs(safe("SELECT ma_sp, ten_sp, gia_ban FROM dbo.SAN_PHAM WHERE trang_thai='DANG_BAN' ORDER BY ten_sp"))["rows"]


def lk_nv(chuc_vu):
    ph = ",".join("?" * len(chuc_vu))
    return rs(safe(f"""SELECT nv.ma_nv, nv.ho_ten, cn.ten_cn, l.chuc_vu, l.ma_cn
                       FROM dbo.LICH_SU_CONG_TAC l JOIN dbo.NHAN_VIEN nv ON nv.ma_nv = l.ma_nv
                       JOIN dbo.CHI_NHANH cn ON cn.ma_cn = l.ma_cn
                       WHERE l.den_ngay IS NULL AND l.chuc_vu IN ({ph}) ORDER BY l.ma_cn, nv.ho_ten""", tuple(chuc_vu)))["rows"]


def lk_khung_gio():
    return rs(safe("SELECT ma_khung_gio, CONVERT(VARCHAR(5), gio_bat_dau, 108) + ' - ' + CONVERT(VARCHAR(5), gio_ket_thuc, 108) FROM dbo.KHUNG_GIO ORDER BY ma_khung_gio"))["rows"]


# ---------------------------------------------------------------------------
# Giao diện
# ---------------------------------------------------------------------------
BASE = """<!doctype html>
<html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title or 'FitLife Hub' }} · FitLife Hub</title>
<style>
:root{--bg:#f4f6f8;--card:#fff;--ink:#17202a;--mut:#5d6b7a;--line:#e2e7ed;--acc:#0b7a75;--acc2:#e8f5f4;--err:#b3261e;--errbg:#fdecea;--ok:#1b6e3c;--okbg:#e6f4ea}
@media (prefers-color-scheme:dark){:root{--bg:#10161c;--card:#18212a;--ink:#e8edf2;--mut:#9aa9b8;--line:#2a3745;--acc:#3fc1b9;--acc2:#16302f;--err:#ff8a80;--errbg:#3a1b19;--ok:#7be0a0;--okbg:#17301f}}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--ink)}
header{background:var(--card);border-bottom:1px solid var(--line);position:sticky;top:0;z-index:5}
.bar{max-width:1180px;margin:0 auto;padding:0 16px;display:flex;align-items:center;gap:20px;flex-wrap:wrap}
.brand{font-weight:700;font-size:18px;padding:12px 0;color:var(--acc)}
nav{display:flex;gap:2px;flex-wrap:wrap}nav a{padding:14px 12px;color:var(--mut);text-decoration:none;border-bottom:2px solid transparent}
nav a:hover{color:var(--ink)}nav a.on{color:var(--acc);border-bottom-color:var(--acc);font-weight:600}
main{max-width:1180px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:22px;margin:4px 0 16px}h2{font-size:17px;margin:0 0 12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:18px;margin-bottom:16px}
.grid{display:grid;gap:16px}.g2{grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
label{display:block;font-size:13px;color:var(--mut);margin:0 0 4px}
input,select,textarea{width:100%;padding:8px 10px;border:1px solid var(--line);border-radius:7px;background:var(--bg);color:var(--ink);font:inherit}
input:focus,select:focus{outline:2px solid var(--acc);border-color:transparent}
.row{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));align-items:end;margin-bottom:12px}
button,.btn{background:var(--acc);color:#fff;border:0;border-radius:7px;padding:9px 16px;font:inherit;font-weight:600;cursor:pointer;text-decoration:none;display:inline-block}
button.sec{background:transparent;color:var(--acc);border:1px solid var(--acc)}button.danger{background:var(--err)}
.msg{padding:10px 14px;border-radius:8px;margin-bottom:12px}.err{background:var(--errbg);color:var(--err)}.ok{background:var(--okbg);color:var(--ok)}
.scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:14px}
th{text-align:left;color:var(--mut);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.03em;white-space:nowrap}
th,td{padding:8px 10px;border-bottom:1px solid var(--line)}tr:last-child td{border-bottom:0}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:12px;background:var(--acc2);color:var(--acc);font-weight:600}
.pill.bad{background:var(--errbg);color:var(--err)}.mut{color:var(--mut)}.big{font-size:26px;font-weight:700}
.inline{display:inline}.small{font-size:13px}canvas{max-height:300px}
</style></head><body>
<header><div class="bar"><div class="brand">FitLife Hub</div><nav>
{% for k,t in menu %}<a href="{{ url_for(k) }}" class="{{ 'on' if active==k else '' }}">{{ t }}</a>{% endfor %}
</nav></div></header>
<main>
{% for cat, m in get_flashed_messages(with_categories=true) %}<div class="msg {{ 'ok' if cat=='ok' else 'err' }}">{{ m }}</div>{% endfor %}
{% block body %}{% endblock %}
</main></body></html>"""

MACROS = """{% macro tbl(rset, link=None) %}
{% if rset.rows %}<div class="scroll"><table><thead><tr>{% for c in rset.cols %}<th>{{ c }}</th>{% endfor %}</tr></thead><tbody>
{% for r in rset.rows %}<tr>{% for v in r %}<td>{% if link and loop.index0==0 %}<a href="{{ link }}{{ v }}">{{ v|fmt }}</a>{% else %}{{ v|fmt }}{% endif %}</td>{% endfor %}</tr>{% endfor %}
</tbody></table></div>{% else %}<p class="mut">Không có dữ liệu.</p>{% endif %}{% endmacro %}
{% macro opts(rows, sel=None, blank=None) %}{% if blank %}<option value="">{{ blank }}</option>{% endif %}
{% for r in rows %}<option value="{{ r[0] }}" {{ 'selected' if sel|string==r[0]|string else '' }}>{{ r[1:]|join(' · ') }}</option>{% endfor %}{% endmacro %}
{% macro chart(id, labels, series, kind='bar') %}<canvas id="{{ id }}"></canvas>
<script>(function(){function go(){new Chart(document.getElementById('{{ id }}'),{type:'{{ kind }}',data:{labels:{{ labels|tojson }},datasets:{{ series|tojson }}},options:{responsive:true,plugins:{legend:{display:{{ 'true' if series|length>1 else 'false' }}}},scales:{y:{beginAtZero:true}}}});}
if(window.Chart)go();else window.addEventListener('load',go);})();</script>{% endmacro %}"""

T = {}
T["base.html"] = BASE
T["macros.html"] = MACROS

T["index.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl, chart %}{% block body %}
<h1>Tổng quan</h1>
<div class="grid g2">
<div class="card"><h2>Doanh thu 30 ngày gần nhất (toàn hệ thống)</h2>
{{ chart('dt', labels, [{'label':'Doanh thu (VNĐ)','data':values,'backgroundColor':'#0b7a75'}], 'bar') }}</div>
<div class="card"><h2>So sánh doanh thu giữa các chi nhánh (30 ngày)</h2>{{ tbl(cn) }}</div>
<div class="card"><h2>Phân bổ hạng hội viên</h2>{{ tbl(hang) }}</div>
<div class="card"><h2>Gói doanh thu cao nhất 6 tháng gần nhất</h2>{{ tbl(goi) }}</div>
</div>{% endblock %}"""

T["hoi_vien.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl %}{% block body %}
<h1>Hội viên</h1>
<div class="card"><form method="get" class="row"><div><label>Tìm theo mã thẻ / SĐT / CCCD / tên (đầu họ tên)</label>
<input name="q" value="{{ q }}" placeholder="vd: 0901234567, FL0000100, Nguyễn" autofocus></div><div><button>Tìm</button>
<a class="btn sec" href="{{ url_for('hoi_vien_them') }}">+ Thêm hội viên</a></div></form>
{% if q %}{{ tbl(kq, '/hoi-vien/') }}{% endif %}</div>{% endblock %}"""

T["hoi_vien_them.html"] = """{% extends 'base.html' %}{% block body %}
<h1>Thêm hội viên</h1><div class="card"><form method="post">
<div class="row"><div><label>Mã thẻ</label><input name="ma_the" required placeholder="FL0030001"></div>
<div><label>Họ tên</label><input name="ho_ten" required></div><div><label>SĐT</label><input name="sdt" required pattern="[0-9]{8,15}"></div>
<div><label>Email</label><input name="email" type="email"></div></div>
<div class="row"><div><label>CCCD (12 số)</label><input name="cccd" required pattern="[0-9]{12}"></div>
<div><label>Giới tính</label><select name="gioi_tinh"><option value="M">Nam</option><option value="F">Nữ</option><option value="O">Khác</option></select></div>
<div><label>Ngày sinh</label><input name="ngay_sinh" type="date" required></div></div>
<button>Lưu</button></form></div>{% endblock %}"""

T["hoi_vien_ct.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl, opts %}{% block body %}
{% if not hv %}<p>Không tìm thấy hội viên.</p>{% else %}
<h1>{{ hv.ho_ten }} <span class="pill {{ 'bad' if hv.trang_thai=='KHOA' else '' }}">{{ hv.trang_thai }}</span>
<span class="pill">{{ hv.ten_hang }}</span></h1>
<div class="grid g2">
<div class="card"><h2>Thông tin</h2>
<form method="post" action="{{ url_for('hoi_vien_sua', ma_hv=hv.ma_hv) }}"><div class="row">
<div><label>Họ tên</label><input name="ho_ten" value="{{ hv.ho_ten }}" required></div>
<div><label>SĐT</label><input name="sdt" value="{{ hv.sdt }}" required></div>
<div><label>Email</label><input name="email" value="{{ hv.email or '' }}"></div></div>
<p class="mut small">Mã thẻ {{ hv.ma_the }} · CCCD {{ hv.cccd }} · sinh {{ hv.ngay_sinh }} · đăng ký {{ hv.ngay_dang_ky }}</p>
<button>Cập nhật</button></form>
<form method="post" action="{{ url_for('hoi_vien_khoa', ma_hv=hv.ma_hv) }}" class="inline">
<input type="hidden" name="khoa" value="{{ 0 if hv.trang_thai=='KHOA' else 1 }}">
<button class="{{ 'sec' if hv.trang_thai=='KHOA' else 'danger' }}" style="margin-top:10px">{{ 'Mở khóa thẻ' if hv.trang_thai=='KHOA' else 'Khóa thẻ (xóa mềm)' }}</button></form></div>
<div class="card"><h2>Thân thiết</h2><p class="big">{{ hv.diem_hien_co|fmt }} <span class="mut small">điểm</span></p>
<p class="mut">Chi tiêu 12 tháng: <b>{{ hv.tong_chi_tieu_12t|fmt }}</b> VNĐ</p><h2 style="margin-top:14px">Quyền vào cổng</h2>{{ tbl(quyen) }}</div>
<div class="card"><h2>Đặt lịch PT</h2>
{% if goi_pt %}<form method="post" action="{{ url_for('lich_pt_dat') }}"><input type="hidden" name="ma_hv" value="{{ hv.ma_hv }}">
<div class="row"><div><label>Gói PT còn buổi</label><select name="ma_goi_mua">{{ opts(goi_pt) }}</select></div>
<div><label>Huấn luyện viên</label><select name="ma_hlv">{{ opts(hlv) }}</select></div></div>
<div class="row"><div><label>Ngày tập</label><input type="date" name="ngay_tap" value="{{ ngay_mac_dinh }}" min="{{ ngay_mac_dinh }}" required></div>
<div><label>Khung giờ</label><select name="ma_khung_gio">{{ opts(khung, 13) }}</select></div></div><button>Đặt lịch</button></form>
{% else %}<p class="mut">Hội viên chưa có gói PT còn hiệu lực/còn buổi.</p>{% endif %}</div>
<div class="card"><h2>Hóa đơn gần đây</h2>{{ tbl(hoadon, '/hoa-don/') }}</div>
</div>
<div class="card"><h2>Lịch hẹn PT (3 tháng gần nhất)</h2><div class="scroll"><table><thead><tr><th>Mã</th><th>Ngày</th><th>Giờ</th><th>HLV</th><th>Chi nhánh</th><th>Trạng thái</th><th>Đánh giá</th><th></th></tr></thead><tbody>
{% for r in lich.rows %}<tr><td>{{ r[0] }}</td><td>{{ r[1]|fmt }}</td><td>{{ r[2]|fmt }}</td><td>{{ r[3] }}</td><td>{{ r[4] }}</td><td>{{ r[5] }}</td><td>{{ r[6]|fmt }}{{ r[7] or '' }}</td>
<td>{% if r[5]=='DA_DAT' %}<form method="post" action="{{ url_for('lich_pt_huy', ma_lich=r[0]) }}" class="inline"><input name="ly_do" placeholder="Lý do hủy" required style="width:140px">
<input type="hidden" name="ma_hv" value="{{ hv.ma_hv }}"><button class="sec">Hủy</button></form>
<form method="post" action="{{ url_for('lich_pt_xong', ma_lich=r[0]) }}" class="inline"><input type="hidden" name="ma_hv" value="{{ hv.ma_hv }}">
<select name="diem" style="width:70px"><option value="">★</option>{% for i in range(5,0,-1) %}<option>{{ i }}</option>{% endfor %}</select><button class="sec">Hoàn thành</button></form>{% endif %}</td></tr>
{% else %}<tr><td colspan="8" class="mut">Không có dữ liệu.</td></tr>{% endfor %}</tbody></table></div></div>
<div class="card"><h2>Lịch sử check-in (3 tháng gần nhất)</h2>{{ tbl(checkin) }}</div>
{% endif %}{% endblock %}"""

T["check_in.html"] = """{% extends 'base.html' %}{% from 'macros.html' import opts %}{% block body %}
<h1>Check-in</h1><div class="card"><form method="post"><div class="row">
<div><label>Mã thẻ / QR</label><input name="ma_the" value="{{ ma_the }}" required autofocus placeholder="FL0000100"></div>
<div><label>Cửa kiểm soát</label><select name="ma_cua">{{ opts(cua, ma_cua) }}</select></div>
<div><button>Quét</button></div></div></form>
{% if kq %}<div class="msg {{ 'ok' if kq.ket_qua=='HOP_LE' else 'err' }}" style="margin-top:12px">
<b>{{ 'HỢP LỆ - mời vào' if kq.ket_qua=='HOP_LE' else 'TỪ CHỐI' }}</b>{% if kq.ly_do %} · {{ kq.ly_do }}{% endif %}
{% if kq.ma_checkin %} · mã lượt #{{ kq.ma_checkin }}{% endif %}{% if ms is not none %} · {{ ms }} ms{% endif %}</div>{% endif %}</div>
<p class="mut small">Thủ tục sp_CheckIn chỉ tra theo khóa: HOI_VIEN(ma_the) → QUYEN_VAO_CONG → CN_DICH_VU, rồi chèn một dòng CHECK_IN.</p>{% endblock %}"""

T["hoa_don.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl, opts %}{% block body %}
<h1>Hóa đơn</h1><div class="grid g2">
<div class="card"><h2>Lập hóa đơn</h2><form method="post" action="{{ url_for('hoa_don_lap') }}">
<div class="row"><div><label>Mã hội viên (để trống = khách lẻ, chỉ mua sản phẩm)</label><input name="ma_hv" type="number" min="1" value="{{ request.args.get('ma_hv','') }}"></div>
<div><label>Chi nhánh</label><select name="ma_cn">{{ opts(cn, 1) }}</select></div></div>
<div class="row"><div><label>Nhân viên lập (lễ tân / NV bán hàng, đúng chi nhánh)</label><select name="ma_nv_lap">{{ opts(nv) }}</select></div>
<div><label>Giảm giá (VNĐ)</label><input name="giam_gia" type="number" min="0" value="0"></div></div>
<label>Gói dịch vụ</label><div class="row">{% for g in goi %}<label style="color:var(--ink)"><input type="checkbox" name="goi" value="{{ g[0] }}" style="width:auto"> {{ g[1] }} <span class="mut">({{ g[2]|fmt }})</span></label>{% endfor %}</div>
<label>Sản phẩm</label>{% for i in range(3) %}<div class="row"><div><select name="sp">{{ opts(sp, None, '— chọn sản phẩm —') }}</select></div><div><input name="sl" type="number" min="1" value="1"></div></div>{% endfor %}
<button>Lập hóa đơn</button></form></div>
<div class="card"><h2>Hóa đơn mới nhất</h2>{{ tbl(gan_day, '/hoa-don/') }}</div></div>{% endblock %}"""

T["hoa_don_ct.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl %}{% block body %}
{% if not hd %}<p>Không tìm thấy hóa đơn.</p>{% else %}
<h1>Hóa đơn #{{ hd.ma_hd }} <span class="pill {{ 'bad' if hd.trang_thai=='DA_HUY' else '' }}">{{ hd.trang_thai }}</span></h1>
<div class="grid g2"><div class="card"><h2>Thông tin</h2>
<p>Chi nhánh <b>{{ hd.ten_cn }}</b> · lập {{ hd.ngay_lap|fmt }} bởi {{ hd.nhan_vien }}<br>
Hội viên: {% if hd.ma_hv %}<a href="{{ url_for('hoi_vien_ct', ma_hv=hd.ma_hv) }}">{{ hd.hoi_vien }}</a>{% else %}khách lẻ{% endif %}</p>
<p>Tổng tiền <b>{{ hd.tong_tien|fmt }}</b> − giảm <b>{{ hd.giam_gia|fmt }}</b> = phải trả <span class="big">{{ hd.thanh_toan|fmt }}</span></p>
<p class="mut">Đã trả: {{ da_tra|fmt }} · còn lại: {{ con_lai|fmt }}</p>
{% if hd.trang_thai=='CHO_THANH_TOAN' %}<form method="post" action="{{ url_for('hoa_don_tt', ma_hd=hd.ma_hd) }}"><div class="row">
<div><label>Hình thức</label><select name="hinh_thuc"><option value="TIEN_MAT">Tiền mặt</option><option value="VNPAY">VNPay</option><option value="THE">Thẻ</option></select></div>
<div><label>Số tiền</label><input name="so_tien" type="number" min="1" value="{{ con_lai|int }}"></div>
<div><label>Mã giao dịch cổng (VNPay/Thẻ)</label><input name="ma_gd"></div></div><button>Thanh toán</button></form>{% endif %}
{% if hd.trang_thai!='DA_HUY' %}<form method="post" action="{{ url_for('hoa_don_huy', ma_hd=hd.ma_hd) }}" class="inline"><button class="danger" style="margin-top:10px">Hủy hóa đơn</button></form>{% endif %}</div>
<div class="card"><h2>Gói dịch vụ</h2>{{ tbl(goi) }}<h2 style="margin-top:14px">Sản phẩm</h2>{{ tbl(sp) }}<h2 style="margin-top:14px">Thanh toán</h2>{{ tbl(tt) }}</div></div>
{% endif %}{% endblock %}"""

T["bao_cao.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl, opts, chart %}{% block body %}
<h1>Báo cáo & thống kê</h1>
<div class="card"><form method="get"><div class="row">
<div><label>Báo cáo</label><select name="loai" onchange="this.form.submit()">{% for k,t in loai_ds %}<option value="{{ k }}" {{ 'selected' if k==loai else '' }}>{{ t }}</option>{% endfor %}</select></div>
{% if 'cn' in dung %}<div><label>Chi nhánh</label><select name="ma_cn">{{ opts(cn, ma_cn, 'Tất cả' if loai in ('doanh_thu','hlv','het_han') else None) }}</select></div>{% endif %}
{% if 'cap' in dung %}<div><label>Cấp</label><select name="cap">{% for k,t in [('NGAY','Ngày'),('THANG','Tháng'),('QUY','Quý'),('NAM','Năm')] %}<option value="{{ k }}" {{ 'selected' if k==cap else '' }}>{{ t }}</option>{% endfor %}</select></div>{% endif %}
{% if 'tu' in dung %}<div><label>Từ ngày</label><input type="date" name="tu" value="{{ tu }}"></div><div><label>Đến ngày</label><input type="date" name="den" value="{{ den }}"></div>{% endif %}
{% if 'ngay' in dung %}<div><label>Ngày</label><input type="date" name="ngay" value="{{ ngay }}"></div><div><label>Từ giờ</label><input type="number" name="gio_tu" min="0" max="23" value="{{ gio_tu }}"></div><div><label>Đến giờ</label><input type="number" name="gio_den" min="0" max="23" value="{{ gio_den }}"></div>{% endif %}
{% if 'thang' in dung %}<div><label>Tháng</label><input type="month" name="thang" value="{{ thang }}"></div><div><label><input type="checkbox" name="chot" value="1" style="width:auto"> Chốt kỳ</label></div>{% endif %}
{% if 'han' in dung %}<div><label>Sắp hết hạn trong (ngày)</label><input type="number" name="n_han" min="1" value="{{ n_han }}"></div><div><label>Vắng quá (ngày)</label><input type="number" name="n_vang" min="1" value="{{ n_vang }}"></div>{% endif %}
<div><button>Xem</button></div></div></form></div>
{% if chart_labels %}<div class="card"><h2>Biểu đồ</h2>{{ chart('c1', chart_labels, chart_series, chart_kind) }}</div>{% endif %}
{% for t, s in ket_qua %}<div class="card"><h2>{{ t }}</h2>{{ tbl(s) }}</div>{% endfor %}{% endblock %}"""

T["nhan_su.html"] = """{% extends 'base.html' %}{% from 'macros.html' import tbl, opts %}{% block body %}
<h1>Nhân sự</h1><div class="grid g2">
<div class="card"><h2>Điều chuyển công tác</h2><form method="post" action="{{ url_for('nhan_su_dieu_chuyen') }}">
<div class="row"><div><label>Nhân viên</label><select name="ma_nv">{{ opts(nv) }}</select></div>
<div><label>Chi nhánh mới</label><select name="ma_cn_moi">{{ opts(cn) }}</select></div>
<div><label>Từ ngày</label><input type="date" name="ngay" value="{{ ngay }}" required></div></div>
<div class="row"><div><label>Lý do</label><input name="ly_do" value="Điều chuyển công tác"></div></div>
<button>Điều chuyển</button></form>
<p class="mut small">Hệ thống đóng giai đoạn cũ, mở giai đoạn mới cùng ngày. HLV còn lịch PT đã đặt từ ngày đó ở chi nhánh cũ sẽ bị từ chối (RB34).</p></div>
<div class="card"><h2>Cập nhật lương cơ bản</h2><form method="post" action="{{ url_for('nhan_su_luong') }}"><div class="row">
<div><label>Nhân viên</label><select name="ma_nv">{{ opts(nv) }}</select></div><div><label>Lương mới (VNĐ)</label><input type="number" name="luong" min="0" step="100000" required></div></div>
<button>Cập nhật</button></form></div></div>
<div class="card"><h2>Lịch sử công tác (gần đây)</h2>{{ tbl(ls) }}</div>{% endblock %}"""

T["404.html"] = "{% extends 'base.html' %}{% block body %}<h1>Không tìm thấy trang</h1>{% endblock %}"

app.jinja_loader = jinja2.DictLoader(T)
app.jinja_env.filters["fmt"] = fmt

MENU = [("index", "Tổng quan"), ("hoi_vien", "Hội viên"), ("check_in", "Check-in"),
        ("hoa_don", "Hóa đơn"), ("bao_cao", "Báo cáo"), ("nhan_su", "Nhân sự")]


@app.context_processor
def inject():
    return {"menu": MENU, "active": request.endpoint}


# ---------------------------------------------------------------------------
# Tổng quan
# ---------------------------------------------------------------------------
@app.route("/")
def index():
    den, tu = date.today(), date.today() - timedelta(days=29)
    dt = rs(safe("EXEC dbo.sp_BaoCaoDoanhThu @cap='NGAY', @tu=?, @den=?", (tu, den)))
    cn = rs(safe("EXEC dbo.sp_DoanhThuToanHeThong @tu=?, @den=?", (tu, den)))
    hang = rs(safe("EXEC dbo.sp_PhanBoHangHoiVien"))
    goi = rs(safe("EXEC dbo.sp_GoiDoanhThuCaoNhat6Thang @top=5"))
    labels = [str(x) for x in col(dt, "ky")]
    values = [num(x) for x in col(dt, "tong_doanh_thu")]
    return render_template("index.html", title="Tổng quan", labels=labels, values=values, cn=cn, hang=hang, goi=goi)


# ---------------------------------------------------------------------------
# Hội viên
# ---------------------------------------------------------------------------
@app.route("/hoi-vien")
def hoi_vien():
    q = request.args.get("q", "").strip()
    kq = rs(safe("EXEC dbo.sp_TraCuuHoiVien @tu_khoa=?", (q,))) if q else {"cols": [], "rows": []}
    return render_template("hoi_vien.html", title="Hội viên", q=q, kq=kq)


@app.route("/hoi-vien/them", methods=["GET", "POST"])
def hoi_vien_them():
    if request.method == "POST":
        f = request.form
        try:
            r = rs(run_sql("EXEC dbo.sp_ThemHoiVien @ma_the=?, @ho_ten=?, @sdt=?, @email=?, @cccd=?, @gioi_tinh=?, @ngay_sinh=?",
                           (f["ma_the"].strip(), f["ho_ten"].strip(), f["sdt"].strip(), f.get("email") or None,
                            f["cccd"].strip(), f["gioi_tinh"], f["ngay_sinh"])))
            flash("Đã thêm hội viên.", "ok")
            return redirect(url_for("hoi_vien_ct", ma_hv=r["rows"][0][0]))
        except Exception as e:  # noqa: BLE001
            msg = friendly_error(e)
            if "UQ_HOI_VIEN" in str(e) or "duplicate" in str(e).lower():
                msg = "Mã thẻ, SĐT hoặc CCCD đã tồn tại (RB10)."
            elif "CK_HOI_VIEN" in str(e):
                msg = "Dữ liệu không hợp lệ (SĐT chỉ gồm chữ số, CCCD đúng 12 số, email đúng dạng, ngày sinh trước ngày đăng ký)."
            flash(msg, "err")
    return render_template("hoi_vien_them.html", title="Thêm hội viên")


@app.route("/hoi-vien/<int:ma_hv>")
def hoi_vien_ct(ma_hv):
    s = safe("""SELECT hv.ma_hv, hv.ma_the, hv.ho_ten, hv.sdt, hv.email, hv.cccd, hv.ngay_sinh, hv.ngay_dang_ky, hv.trang_thai,
                       h.ten_hang, t.diem_hien_co, t.tong_chi_tieu_12t
                FROM dbo.HOI_VIEN hv LEFT JOIN dbo.TAI_KHOAN_LOYALTY t ON t.ma_hv = hv.ma_hv
                LEFT JOIN dbo.HANG_THANH_VIEN h ON h.ma_hang = t.ma_hang WHERE hv.ma_hv = ?""", (ma_hv,))
    r = rs(s)
    if not r["rows"]:
        return render_template("hoi_vien_ct.html", title="Hội viên", hv=None)
    hv = dict(zip(r["cols"], r["rows"][0]))
    quyen = rs(safe("""SELECT dv.ten_dv AS dich_vu, q.ngay_het_han, q.so_luot_con_lai AS luot_con_lai
                       FROM dbo.QUYEN_VAO_CONG q JOIN dbo.DICH_VU dv ON dv.ma_dv = q.ma_dv WHERE q.ma_hv = ?""", (ma_hv,)))
    goi_pt = rs(safe("""SELECT g.ma_goi_mua, d.ten_goi + ' · còn ' + CAST(g.so_buoi_con_lai AS VARCHAR(5)) + ' buổi · hết hạn ' + CONVERT(VARCHAR(10), g.ngay_het_han, 23)
                        FROM dbo.GOI_DA_MUA g JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
                        JOIN dbo.DICH_VU v ON v.ma_dv = d.ma_dv AND v.nhom_dv = 'PT'
                        WHERE h.ma_hv = ? AND g.trang_thai = 'HIEU_LUC' AND g.so_buoi_con_lai > 0
                          AND g.ngay_het_han >= CAST(SYSDATETIME() AS DATE)""", (ma_hv,)))["rows"]
    hoadon = rs(safe("""SELECT TOP (10) ma_hd, ngay_lap, thanh_toan, trang_thai FROM dbo.HOA_DON WHERE ma_hv = ? ORDER BY ma_hd DESC""", (ma_hv,)))
    ls = safe("EXEC dbo.sp_LichSuTap @ma_hv=?", (ma_hv,))
    return render_template("hoi_vien_ct.html", title=hv["ho_ten"], hv=type("H", (), hv), quyen=quyen, goi_pt=goi_pt,
                           hlv=lk_nv(["PT"]), khung=lk_khung_gio(), ngay_mac_dinh=(date.today() + timedelta(days=1)).isoformat(),
                           hoadon=hoadon, checkin=rs(ls, 0), lich=rs(ls, 1))


@app.post("/hoi-vien/<int:ma_hv>/sua")
def hoi_vien_sua(ma_hv):
    f = request.form
    try:
        run_sql("EXEC dbo.sp_CapNhatHoiVien @ma_hv=?, @ho_ten=?, @sdt=?, @email=?",
                (ma_hv, f["ho_ten"].strip(), f["sdt"].strip(), f.get("email") or None))
        flash("Đã cập nhật.", "ok")
    except Exception as e:  # noqa: BLE001
        flash("SĐT đã thuộc hội viên khác." if "UQ_HOI_VIEN" in str(e) else friendly_error(e), "err")
    return redirect(url_for("hoi_vien_ct", ma_hv=ma_hv))


@app.post("/hoi-vien/<int:ma_hv>/khoa")
def hoi_vien_khoa(ma_hv):
    khoa = int(request.form.get("khoa", 1))
    try:
        run_sql("EXEC dbo.sp_KhoaHoiVien @ma_hv=?, @khoa=?", (ma_hv, khoa))
        flash("Đã khóa thẻ." if khoa else "Đã mở khóa thẻ.", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("hoi_vien_ct", ma_hv=ma_hv))


# ---------------------------------------------------------------------------
# Lịch PT
# ---------------------------------------------------------------------------
@app.post("/lich-pt/dat")
def lich_pt_dat():
    f = request.form
    ma_hv = int(f["ma_hv"])
    try:
        r = rs(run_sql("EXEC dbo.sp_DatLichPT @ma_hv=?, @ma_goi_mua=?, @ma_hlv=?, @ngay_tap=?, @ma_khung_gio=?",
                       (ma_hv, int(f["ma_goi_mua"]), int(f["ma_hlv"]), f["ngay_tap"], int(f["ma_khung_gio"]))))
        flash(f"Đã đặt lịch PT #{r['rows'][0][0]}.", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("hoi_vien_ct", ma_hv=ma_hv))


@app.post("/lich-pt/<int:ma_lich>/huy")
def lich_pt_huy(ma_lich):
    ma_hv = int(request.form["ma_hv"])
    try:
        run_sql("EXEC dbo.sp_HuyLichPT @ma_lich=?, @ly_do=?", (ma_lich, request.form["ly_do"].strip()))
        flash("Đã hủy lịch và hoàn 1 buổi.", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("hoi_vien_ct", ma_hv=ma_hv))


@app.post("/lich-pt/<int:ma_lich>/hoan-thanh")
def lich_pt_xong(ma_lich):
    ma_hv = int(request.form["ma_hv"])
    d = request.form.get("diem")
    try:
        run_sql("EXEC dbo.sp_HoanThanhLichPT @ma_lich=?, @diem_danh_gia=?", (ma_lich, int(d) if d else None))
        flash("Đã đánh dấu hoàn thành.", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("hoi_vien_ct", ma_hv=ma_hv))


# ---------------------------------------------------------------------------
# Check-in
# ---------------------------------------------------------------------------
@app.route("/check-in", methods=["GET", "POST"])
def check_in():
    cua = rs(safe("""SELECT k.ma_cua, cn.ten_cn, k.vi_tri FROM dbo.CUA_KIEM_SOAT k JOIN dbo.CHI_NHANH cn ON cn.ma_cn = k.ma_cn
                     WHERE k.trang_thai = 'HOAT_DONG' ORDER BY k.ma_cua"""))["rows"]
    kq, ms, ma_the, ma_cua = None, None, "", 1
    if request.method == "POST":
        import time
        ma_the, ma_cua = request.form["ma_the"].strip(), int(request.form["ma_cua"])
        t0 = time.perf_counter()
        try:
            r = rs(run_sql("EXEC dbo.sp_CheckIn @ma_the=?, @ma_cua=?", (ma_the, ma_cua)))
            ms = round((time.perf_counter() - t0) * 1000)
            kq = type("K", (), dict(zip(r["cols"], r["rows"][0])))
        except Exception as e:  # noqa: BLE001
            flash(friendly_error(e), "err")
    return render_template("check_in.html", title="Check-in", cua=cua, kq=kq, ms=ms, ma_the=ma_the, ma_cua=ma_cua)


# ---------------------------------------------------------------------------
# Hóa đơn và thanh toán
# ---------------------------------------------------------------------------
@app.route("/hoa-don")
def hoa_don():
    gan = rs(safe("""SELECT TOP (15) hd.ma_hd, hd.ngay_lap, cn.ten_cn, hd.thanh_toan, hd.trang_thai
                     FROM dbo.HOA_DON hd JOIN dbo.CHI_NHANH cn ON cn.ma_cn = hd.ma_cn ORDER BY hd.ma_hd DESC"""))
    return render_template("hoa_don.html", title="Hóa đơn", cn=lk_chi_nhanh(), nv=lk_nv(["LE_TAN", "NV_BAN_HANG"]),
                           goi=lk_goi(), sp=lk_san_pham(), gan_day=gan)


@app.post("/hoa-don/lap")
def hoa_don_lap():
    f = request.form
    try:
        goi = [int(x) for x in f.getlist("goi")]
        sp = {}
        for s, sl in zip(f.getlist("sp"), f.getlist("sl")):
            if s:
                sp[int(s)] = sp.get(int(s), 0) + max(1, int(sl or 1))
        ma_hv = int(f["ma_hv"]) if f.get("ma_hv") else None
        batch = "SET NOCOUNT ON; DECLARE @g dbo.ds_goi, @s dbo.ds_sp, @hd BIGINT;"
        if goi:
            batch += " INSERT INTO @g (ma_goi) VALUES " + ",".join(f"({g})" for g in goi) + ";"
        if sp:
            batch += " INSERT INTO @s (ma_sp, so_luong) VALUES " + ",".join(f"({k},{v})" for k, v in sp.items()) + ";"
        batch += (" EXEC dbo.sp_LapHoaDon @ma_hv=?, @ma_nv_lap=?, @ma_cn=?, @goi=@g, @sp=@s, @giam_gia=?, @ma_hd=@hd OUTPUT;")
        r = rs(run_sql(batch, (ma_hv, int(f["ma_nv_lap"]), int(f["ma_cn"]), int(f.get("giam_gia") or 0))))
        flash("Đã lập hóa đơn, chờ thanh toán.", "ok")
        return redirect(url_for("hoa_don_ct", ma_hd=r["rows"][0][0]))
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
        return redirect(url_for("hoa_don"))


@app.route("/hoa-don/<int:ma_hd>")
def hoa_don_ct(ma_hd):
    r = rs(safe("""SELECT hd.ma_hd, hd.ma_hv, hv.ho_ten AS hoi_vien, nv.ho_ten AS nhan_vien, cn.ten_cn, hd.ngay_lap,
                          hd.tong_tien, hd.giam_gia, hd.thanh_toan, hd.trang_thai
                   FROM dbo.HOA_DON hd JOIN dbo.CHI_NHANH cn ON cn.ma_cn = hd.ma_cn JOIN dbo.NHAN_VIEN nv ON nv.ma_nv = hd.ma_nv_lap
                   LEFT JOIN dbo.HOI_VIEN hv ON hv.ma_hv = hd.ma_hv WHERE hd.ma_hd = ?""", (ma_hd,)))
    if not r["rows"]:
        return render_template("hoa_don_ct.html", title="Hóa đơn", hd=None)
    hd = dict(zip(r["cols"], r["rows"][0]))
    goi = rs(safe("""SELECT d.ten_goi, g.don_gia, g.ngay_bat_dau, g.ngay_het_han, g.so_buoi_con_lai, g.trang_thai
                     FROM dbo.GOI_DA_MUA g JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi WHERE g.ma_hd = ?""", (ma_hd,)))
    sp = rs(safe("""SELECT p.ten_sp, c.so_luong, c.don_gia, c.so_luong * c.don_gia AS thanh_tien
                    FROM dbo.CT_HD_SAN_PHAM c JOIN dbo.SAN_PHAM p ON p.ma_sp = c.ma_sp WHERE c.ma_hd = ?""", (ma_hd,)))
    tt = rs(safe("SELECT hinh_thuc, so_tien, trang_thai, thoi_diem, ma_giao_dich_cong FROM dbo.THANH_TOAN WHERE ma_hd = ? ORDER BY ma_tt", (ma_hd,)))
    da_tra = sum(num(x[1]) for x in tt["rows"] if x[2] == "THANH_CONG")
    return render_template("hoa_don_ct.html", title=f"Hóa đơn #{ma_hd}", hd=type("D", (), hd), goi=goi, sp=sp, tt=tt,
                           da_tra=da_tra, con_lai=max(0.0, num(hd["thanh_toan"]) - da_tra))


@app.post("/hoa-don/<int:ma_hd>/thanh-toan")
def hoa_don_tt(ma_hd):
    f = request.form
    try:
        run_sql("EXEC dbo.sp_ThanhToan @ma_hd=?, @hinh_thuc=?, @so_tien=?, @ma_giao_dich_cong=?",
                (ma_hd, f["hinh_thuc"], int(f["so_tien"]), (f.get("ma_gd") or "").strip() or None))
        flash("Đã ghi nhận thanh toán.", "ok")
    except Exception as e:  # noqa: BLE001
        msg = friendly_error(e)
        if "CK_THANH_TOAN_ma_gd" in str(e):
            msg = "VNPay/Thẻ bắt buộc có mã giao dịch cổng (RB23)."
        elif "UX_THANH_TOAN_ma_gd" in str(e):
            msg = "Mã giao dịch cổng đã được dùng (RB14)."
        flash(msg, "err")
    return redirect(url_for("hoa_don_ct", ma_hd=ma_hd))


@app.post("/hoa-don/<int:ma_hd>/huy")
def hoa_don_huy(ma_hd):
    try:
        run_sql("EXEC dbo.sp_HuyHoaDon @ma_hd=?", (ma_hd,))
        flash("Đã hủy hóa đơn (hoàn tiền, hoàn điểm, hoàn kho).", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("hoa_don_ct", ma_hd=ma_hd))


# ---------------------------------------------------------------------------
# Báo cáo
# ---------------------------------------------------------------------------
LOAI = [("doanh_thu", "Doanh thu theo ngày/tháng/quý/năm"), ("he_thong", "So sánh doanh thu các chi nhánh"),
        ("lap_day", "Tỷ lệ lấp đầy theo khung giờ"), ("ds_gio", "Hội viên check-in theo khung giờ"),
        ("ban_chay", "Gói/sản phẩm bán chạy"), ("ton_kho", "Tồn kho thực phẩm bổ sung/phụ kiện"),
        ("hlv", "Hiệu suất HLV"), ("het_han", "Hội viên sắp hết hạn / lâu chưa quay lại"),
        ("hang", "Phân bổ hạng hội viên"), ("goi_6t", "Gói doanh thu cao nhất 6 tháng"),
        ("hoa_hong", "Hoa hồng PT theo tháng")]
DUNG = {"doanh_thu": {"cn", "cap", "tu"}, "he_thong": {"tu"}, "lap_day": {"cn", "tu"}, "ds_gio": {"cn", "ngay"},
        "ban_chay": {"cn", "tu"}, "ton_kho": {"cn"}, "hlv": {"cn", "tu"}, "het_han": {"cn", "han"},
        "hang": set(), "goi_6t": set(), "hoa_hong": {"thang"}}


@app.route("/bao-cao")
def bao_cao():
    a = request.args
    loai = a.get("loai", "doanh_thu")
    if loai not in DUNG:
        loai = "doanh_thu"
    today = date.today()
    ma_cn = a.get("ma_cn") or ("1" if loai in ("lap_day", "ds_gio", "ban_chay", "ton_kho") else "")
    cap = a.get("cap", "THANG")
    tu = a.get("tu") or (today - timedelta(days=(30 if cap == "NGAY" else 365))).isoformat()
    den = a.get("den") or today.isoformat()
    ngay = a.get("ngay") or today.isoformat()
    gio_tu, gio_den = int(a.get("gio_tu", 17)), int(a.get("gio_den", 20))
    thang = a.get("thang") or (today.replace(day=1) - timedelta(days=1)).strftime("%Y-%m")
    n_han, n_vang = int(a.get("n_han", 14)), int(a.get("n_vang", 30))
    cnv = int(ma_cn) if ma_cn else None
    kq, labels, series, kind = [], [], [], "bar"
    if loai == "doanh_thu":
        r = rs(safe("EXEC dbo.sp_BaoCaoDoanhThu @cap=?, @tu=?, @den=?, @ma_cn=?", (cap, tu, den, cnv)))
        kq = [("Doanh thu", r)]
        labels = [str(x)[:10] for x in col(r, "ky")]
        series = [{"label": "Doanh thu gói", "data": [num(x) for x in col(r, "doanh_thu_goi")], "backgroundColor": "#0b7a75"},
                  {"label": "Doanh thu sản phẩm", "data": [num(x) for x in col(r, "doanh_thu_san_pham")], "backgroundColor": "#e0a030"}]
    elif loai == "he_thong":
        r = rs(safe("EXEC dbo.sp_DoanhThuToanHeThong @tu=?, @den=?", (tu, den)))
        kq = [("Doanh thu theo chi nhánh", r)]
        labels, series = col(r, "ten_cn"), [{"label": "Doanh thu", "data": [num(x) for x in col(r, "doanh_thu")], "backgroundColor": "#0b7a75"}]
    elif loai == "lap_day":
        r = rs(safe("EXEC dbo.sp_BaoCaoLapDay @ma_cn=?, @tu=?, @den=?", (cnv, tu, den)))
        kq = [("Tỷ lệ lấp đầy theo giờ", r)]
        labels = [f"{g}h" for g in col(r, "gio")]
        series = [{"label": "Lấp đầy (%)", "data": [num(x) for x in col(r, "ty_le_lap_day_pct")], "backgroundColor": "#0b7a75"}]
    elif loai == "ds_gio":
        kq = [("Danh sách check-in", rs(safe("EXEC dbo.sp_DSCheckInTheoGio @ma_cn=?, @ngay=?, @gio_tu=?, @gio_den=?", (cnv, ngay, gio_tu, gio_den))))]
    elif loai == "ban_chay":
        s = safe("EXEC dbo.sp_TopGoiSanPham @ma_cn=?, @tu=?, @den=?, @top=10", (cnv, tu, den))
        kq = [("Gói bán chạy", rs(s, 0)), ("Sản phẩm bán chạy", rs(s, 1))]
    elif loai == "ton_kho":
        kq = [("Tồn kho", rs(safe("EXEC dbo.sp_BaoCaoTonKho @ma_cn=?, @chi_canh_bao=0", (cnv,))))]
    elif loai == "hlv":
        kq = [("Hiệu suất HLV", rs(safe("EXEC dbo.sp_HieuSuatHLV @ma_cn=?, @tu=?, @den=?", (cnv, tu, den))))]
    elif loai == "het_han":
        kq = [("Hội viên cần chăm sóc", rs(safe("EXEC dbo.sp_HoiVienSapHetHan @ma_cn=?, @so_ngay_het_han=?, @so_ngay_vang=?", (cnv, n_han, n_vang))))]
    elif loai == "hang":
        r = rs(safe("EXEC dbo.sp_PhanBoHangHoiVien"))
        kq = [("Phân bổ hạng", r)]
        labels, series, kind = col(r, "ten_hang"), [{"label": "Hội viên", "data": [num(x) for x in col(r, "so_hoi_vien")],
                                                     "backgroundColor": ["#9aa9b8", "#e0a030", "#0b7a75"]}], "bar"
    elif loai == "goi_6t":
        kq = [("Gói doanh thu cao nhất", rs(safe("EXEC dbo.sp_GoiDoanhThuCaoNhat6Thang @top=10")))]
    elif loai == "hoa_hong":
        kq = [("Hoa hồng PT", rs(safe("EXEC dbo.sp_TinhHoaHongThang @thang=?, @chot=?", (thang + "-01", 1 if a.get("chot") else 0))))]
    return render_template("bao_cao.html", title="Báo cáo", loai=loai, loai_ds=LOAI, dung=DUNG[loai], cn=lk_chi_nhanh(), ma_cn=ma_cn,
                           cap=cap, tu=tu, den=den, ngay=ngay, gio_tu=gio_tu, gio_den=gio_den, thang=thang, n_han=n_han, n_vang=n_vang,
                           ket_qua=kq, chart_labels=[x for x in labels], chart_series=series, chart_kind=kind)


# ---------------------------------------------------------------------------
# Nhân sự
# ---------------------------------------------------------------------------
@app.route("/nhan-su")
def nhan_su():
    nv = rs(safe("""SELECT nv.ma_nv, nv.ho_ten, l.chuc_vu, cn.ten_cn FROM dbo.NHAN_VIEN nv
                    JOIN dbo.LICH_SU_CONG_TAC l ON l.ma_nv = nv.ma_nv AND l.den_ngay IS NULL
                    JOIN dbo.CHI_NHANH cn ON cn.ma_cn = l.ma_cn WHERE nv.trang_thai = 'DANG_LAM' ORDER BY cn.ma_cn, l.chuc_vu, nv.ho_ten"""))["rows"]
    ls = rs(safe("""SELECT TOP (30) l.ma_ls, nv.ho_ten, cn.ten_cn, l.chuc_vu, l.tu_ngay, l.den_ngay, l.ly_do
                    FROM dbo.LICH_SU_CONG_TAC l JOIN dbo.NHAN_VIEN nv ON nv.ma_nv = l.ma_nv JOIN dbo.CHI_NHANH cn ON cn.ma_cn = l.ma_cn
                    WHERE l.ly_do IS NOT NULL ORDER BY l.ma_ls DESC"""))
    return render_template("nhan_su.html", title="Nhân sự", nv=nv, cn=lk_chi_nhanh(), ls=ls,
                           ngay=(date.today() + timedelta(days=7)).isoformat())


@app.post("/nhan-su/dieu-chuyen")
def nhan_su_dieu_chuyen():
    f = request.form
    try:
        run_sql("EXEC dbo.sp_DieuChuyenNhanVien @ma_nv=?, @ma_cn_moi=?, @ngay=?, @ly_do=?",
                (int(f["ma_nv"]), int(f["ma_cn_moi"]), f["ngay"], f.get("ly_do") or "Điều chuyển công tác"))
        flash("Đã điều chuyển nhân viên.", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("nhan_su"))


@app.post("/nhan-su/luong")
def nhan_su_luong():
    try:
        run_sql("EXEC dbo.sp_CapNhatLuong @ma_nv=?, @luong_moi=?", (int(request.form["ma_nv"]), int(request.form["luong"])))
        flash("Đã cập nhật lương cơ bản.", "ok")
    except Exception as e:  # noqa: BLE001
        flash(friendly_error(e), "err")
    return redirect(url_for("nhan_su"))


def main():
    ap = argparse.ArgumentParser(description="FitLife Hub web app")
    ap.add_argument("--server", default=CONFIG["server"])
    ap.add_argument("--database", default=CONFIG["database"])
    ap.add_argument("--user")
    ap.add_argument("--password", default=CONFIG["password"])
    ap.add_argument("--driver")
    ap.add_argument("--port", type=int, default=5000)
    a = ap.parse_args()
    CONFIG.update(server=a.server, database=a.database, user=a.user, password=a.password, driver=a.driver)
    app.run(host="127.0.0.1", port=a.port, debug=False)


if __name__ == "__main__":
    main()
