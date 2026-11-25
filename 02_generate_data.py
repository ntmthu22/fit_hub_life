#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FitLife Hub - CSC12002 - Script 02: sinh dữ liệu mô phỏng cho database FitLifeHub.

Quy mô mặc định (scale = 1.0), 365 ngày gần nhất tính đến hôm qua:
    12 chi nhánh | ~30.000 hội viên | ~360 nhân viên (~120 HLV)
    ~1.500 hóa đơn/ngày (~550k)   | ~500 gói đã mua/ngày
    ~7.300 check-in/ngày (~2,7 triệu), ~61% rơi vào 17h-20h
    ~300.000 lịch PT, 300 sản phẩm x 12 chi nhánh tồn kho
    (đã chạy thử --dry-run ở scale 1.0: ~23 giây, HOA_DON 539.798, GOI_DA_MUA 182.113, THANH_TOAN 649.045)

Dữ liệu tuân thủ các ràng buộc ở Phần 2 (RB01-RB42) mà trigger Giai đoạn 2 sẽ kiểm:
    giá chốt, tổng tiền = tổng dòng, thanh toán = tổng - giảm giá, điểm = FLOOR(tt/100000),
    check-in hợp lệ chỉ với gói đang hiệu lực + dịch vụ có tại chi nhánh, mỗi hội viên
    tối đa một lượt/ngày (không chồng lượt), lịch PT khớp chi nhánh HLV tại ngày tập,
    không trùng (HLV, ngày, khung giờ), PT chuyển chi nhánh giữa kỳ...

Cách chạy (database phải vừa tạo bằng 01_create_schema.sql, còn trống):
    pip install pyodbc numpy faker
    python 02_generate_data.py                              # localhost, Windows Authentication
    python 02_generate_data.py --server "localhost\\SQLEXPRESS"
    python 02_generate_data.py --user sa --password "..."   # SQL login (hoặc biến môi trường FITLIFE_PWD)
    python 02_generate_data.py --dry-run --scale 0.05       # chỉ sinh + kiểm tra trong bộ nhớ, không ghi DB
Tùy chọn khác: --scale 0.1 (thu nhỏ), --seed 42, --no-fast (nếu fast_executemany báo lỗi kiểu dữ liệu).
"""
import argparse
import bisect
import calendar
import itertools
import os
import random
import sys
import time
from collections import defaultdict
from datetime import date, datetime, time as dtime, timedelta
from decimal import Decimal

import numpy as np


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def add_months(d, m):
    y = d.year + (d.month - 1 + m) // 12
    mo = (d.month - 1 + m) % 12 + 1
    return date(y, mo, min(d.day, calendar.monthrange(y, mo)[1]))


def r1000(x):
    return int(round(x / 1000.0)) * 1000


def make_cum(weights):
    w = np.asarray(weights, dtype=float)
    c = np.cumsum(w) / w.sum()
    c[-1] = 1.0 + 1e-9
    return c.tolist()


def pick(cum, u):
    return min(bisect.bisect_right(cum, u), len(cum) - 1)


# --------------------------------------------------------------------------
# Danh mục cố định
# --------------------------------------------------------------------------
BRANCH_DEFS = [  # (quận/khu vực, thành phố)
    ("Quận 1", "TP. Hồ Chí Minh"), ("Quận 3", "TP. Hồ Chí Minh"),
    ("Thủ Đức", "TP. Hồ Chí Minh"), ("Tân Bình", "TP. Hồ Chí Minh"),
    ("Cầu Giấy", "Hà Nội"), ("Hoàn Kiếm", "Hà Nội"), ("Hà Đông", "Hà Nội"),
    ("Hải Châu", "Đà Nẵng"), ("Sơn Trà", "Đà Nẵng"),
    ("Ninh Kiều", "Cần Thơ"), ("Lê Chân", "Hải Phòng"), ("Lộc Thọ", "Nha Trang"),
]
NB = len(BRANCH_DEFS)
BRANCH_W = [1.4, 1.2, 1.3, 1.1, 1.2, 1.0, 0.8, 0.9, 0.8, 0.7, 0.6, 0.6]
STREETS = ["Nguyễn Huệ", "Lê Lợi", "Trần Hưng Đạo", "Hai Bà Trưng", "Lý Thường Kiệt", "Phạm Văn Đồng",
           "Nguyễn Trãi", "Võ Văn Tần", "Điện Biên Phủ", "Cách Mạng Tháng 8", "Nguyễn Văn Linh", "Trần Phú"]

# dịch vụ: tên -> (nhóm, mô tả sức chứa)
SERVICES = ["Gym", "Yoga", "GroupX", "PT 1-1", "Spa", "Sauna", "Cửa hàng"]
SVC_CAP = {"Gym": (150, 250), "Yoga": (30, 45), "GroupX": (40, 60), "Sauna": (15, 25), "Spa": (20, 35)}
SVC_CODE = {"Gym": 0, "Yoga": 1, "GroupX": 2, "PT 1-1": 3, "Spa": 4}
YOGA_MISSING = {12}              # chi nhánh không có Yoga
SPA_BRANCHES = {1, 2, 3, 5, 6, 8, 10, 11}


def offered(svc, b):
    if svc == "Yoga":
        return b not in YOGA_MISSING
    if svc == "Spa":
        return b in SPA_BRANCHES
    return True


# (tên gói, dịch vụ, thời hạn tháng, số buổi PT, giá, trọng số bán)
PKGS = [
    ("Gym 3 tháng", "Gym", 3, None, 1_800_000, 11),
    ("Gym 6 tháng", "Gym", 6, None, 3_200_000, 8),
    ("Gym 12 tháng", "Gym", 12, None, 5_600_000, 5),
    ("Yoga 3 tháng", "Yoga", 3, None, 2_400_000, 5),
    ("Yoga 6 tháng", "Yoga", 6, None, 4_300_000, 3),
    ("Yoga 12 tháng", "Yoga", 12, None, 7_500_000, 2),
    ("GroupX 3 tháng", "GroupX", 3, None, 2_100_000, 5),
    ("GroupX 6 tháng", "GroupX", 6, None, 3_800_000, 3),
    ("GroupX 12 tháng", "GroupX", 12, None, 6_600_000, 2),
    ("PT 1-1 10 buổi", "PT 1-1", 3, 10, 4_500_000, 5),
    ("PT 1-1 20 buổi", "PT 1-1", 6, 20, 8_400_000, 3.5),
    ("PT 1-1 36 buổi", "PT 1-1", 12, 36, 14_400_000, 2.5),
    ("Vé Spa lẻ", "Spa", None, None, 450_000, 25),
]

# giờ 5..21 (17 giá trị): ~60% rơi vào 17h-20h
HOUR_W = [1, 3, 3.5, 2.5, 1.5, 1.5, 2, 2.5, 1.5, 1, 1.5, 3, 15, 17, 14, 3, 1.5]
HOUR_P = np.asarray(HOUR_W, dtype=float) / sum(HOUR_W)

PRODUCT_CATS = [  # (loại, mẫu tên, danh sách biến thể (itertools.product), giá min, giá max, đơn vị)
    ("Whey protein", "Whey Protein {} {}", ["Optimum Nutrition", "MyProtein", "Rule 1", "BSN", "Dymatize", "Muscletech", "Nutrex", "Kaged", "Evlution", "Ghost"], ["2lbs", "5lbs", "10lbs"], 900_000, 2_800_000, "hũ"),
    ("BCAA/EAA", "BCAA {} {}", ["Scivation", "MyProtein", "Optimum Nutrition", "Evlution", "Kaged", "Nutrex", "BSN", "Ghost"], ["Cam", "Dâu", "Chanh", "Nho", "Dưa hấu", "Xoài", "Táo"], 450_000, 900_000, "hũ"),
    ("Pre-workout", "Pre-workout {} {}", ["C4", "Gorilla Mode", "Ghost", "Kaged", "Bucked Up", "Cellucor", "Alani Nu"], ["Cam", "Dâu", "Chanh", "Nho", "Dưa hấu", "Xoài"], 500_000, 1_100_000, "hũ"),
    ("Creatine", "Creatine {} {}", ["Optimum Nutrition", "MyProtein", "Kaged", "Nutrex", "BulkPowders", "Now Sports", "Cellucor", "Allmax", "Muscletech"], ["300g", "500g", "1kg"], 350_000, 850_000, "hũ"),
    ("Thanh protein", "Protein Bar {} {}", ["Quest", "Fit Crunch", "Barebells", "Optimum Nutrition", "One Bar", "Built Bar"], ["Socola", "Bơ đậu phộng", "Caramel", "Cookies", "Dâu", "Chuối"], 35_000, 60_000, "thanh"),
    ("Bình nước", "Bình nước {} {}", ["Đen", "Trắng", "Xanh navy", "Xanh lá", "Hồng", "Xám", "Cam", "Đỏ"], ["500ml", "750ml", "1L", "2L"], 80_000, 350_000, "cái"),
    ("Thảm yoga", "Thảm yoga {} {}", ["4mm", "6mm", "8mm"], ["Tím", "Xanh dương", "Xanh lá", "Hồng", "Đen", "Xám", "Cam", "Đỏ", "Vàng"], 180_000, 650_000, "tấm"),
    ("Găng tay tập", "Găng tay tập gym {} {}", ["Harbinger", "Nike", "Adidas", "Under Armour", "Reebok", "Everlast", "Venum", "RDX", "Gymshark", "Puma"], ["S", "M", "L", "XL"], 120_000, 350_000, "đôi"),
    ("Dây kháng lực", "Dây kháng lực {} {}", ["Nike", "Adidas", "Reebok", "Fit Simplify", "TheraBand", "Everlast", "RDX", "Gymshark", "Puma", "Decathlon"], ["ngũ sắc", "mini band", "kéo lưng", "dạng ống"], 90_000, 400_000, "bộ"),
    ("Khăn tập", "Khăn tập {} {}", ["Trắng", "Xám", "Đen", "Xanh dương", "Xanh lá", "Hồng", "Cam", "Đỏ", "Tím", "Vàng"], ["nhỏ", "vừa", "lớn"], 50_000, 150_000, "cái"),
    ("Túi thể thao", "Túi thể thao {} {}", ["Nike", "Adidas", "Under Armour", "Puma", "Gymshark", "Decathlon", "Reebok", "Everlast", "Lululemon", "Umbro"], ["duffel", "balo", "tote"], 250_000, 900_000, "cái"),
    ("Vitamin & khoáng chất", "{} {}", ["Nature Made", "Now Foods", "Centrum", "Blackmores", "Kirkland", "Swisse"], ["Multivitamin", "Omega-3", "Vitamin D3", "Magie", "Vitamin C", "Kẽm"], 200_000, 600_000, "hộp"),
]
PRODUCTS_PER_CAT = 25

ROLE_COUNTS = [("QUAN_LY", 1), ("PT", 10), ("LE_TAN", 5), ("NV_BAN_HANG", 14)]  # 30 nhân viên/chi nhánh
SALARY = {"QUAN_LY": (20, 30), "PT": (9, 15), "LE_TAN": (8, 10), "NV_BAN_HANG": (7, 9)}  # triệu
CHUYEN_MON = ["Tăng cơ", "Giảm mỡ", "Yoga trị liệu", "Boxing", "Phục hồi chức năng", "Tăng sức bền", "Thể hình nữ", "Calisthenics"]
CHUNG_CHI = ["NASM-CPT", "ACE Personal Trainer", "ISSA-CPT", "ACSM-CPT", "Chứng chỉ HLV quốc gia", "CrossFit Level 1"]
CANCEL_REASONS = ["Hội viên bận đột xuất", "HLV nghỉ ốm", "Đổi lịch cá nhân", "Thời tiết xấu", "Hội viên không khỏe", "Trùng lịch công tác"]
REVIEWS = ["Buổi tập rất hiệu quả", "HLV nhiệt tình, chuyên nghiệp", "Bài tập phù hợp với thể trạng", "Cần thêm bài tập cardio", "Rất hài lòng"]
CCCD_PREFIX = ["001", "079", "048", "031", "092", "056", "075", "038", "040", "066"]
PHONE_PREFIX = ["090", "091", "093", "094", "097", "098", "032", "033", "070", "076", "077", "078", "079", "081", "082", "083"]


def parse_args():
    ap = argparse.ArgumentParser(description="Sinh dữ liệu mô phỏng cho FitLifeHub")
    ap.add_argument("--server", default=os.environ.get("FITLIFE_SERVER", "localhost"))
    ap.add_argument("--database", default="FitLifeHub")
    ap.add_argument("--user", default=None)
    ap.add_argument("--password", default=os.environ.get("FITLIFE_PWD"))
    ap.add_argument("--driver", default=None)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=2627)
    ap.add_argument("--dry-run", action="store_true", help="chỉ sinh trong bộ nhớ, không ghi DB")
    ap.add_argument("--no-fast", action="store_true", help="tắt fast_executemany")
    return ap.parse_args()


class Loader:
    """Ghi dữ liệu theo lô; ở chế độ dry-run chỉ đếm."""

    def __init__(self, args):
        self.dry = args.dry_run
        self.counts = {}
        if self.dry:
            self.conn = None
            return
        import pyodbc
        driver = args.driver
        if not driver:
            cands = [d for d in pyodbc.drivers() if "SQL Server" in d]
            odbc = sorted([d for d in cands if d.startswith("ODBC Driver")], reverse=True)
            driver = (odbc or cands or [None])[0]
            if not driver:
                sys.exit("Không tìm thấy ODBC driver cho SQL Server. Cài 'ODBC Driver 17/18 for SQL Server'.")
        cs = f"DRIVER={{{driver}}};SERVER={args.server};DATABASE={args.database};TrustServerCertificate=yes;"
        cs += f"UID={args.user};PWD={args.password};" if args.user else "Trusted_Connection=yes;"
        log(f"Kết nối: {driver} | {args.server} | {args.database}")
        self.conn = pyodbc.connect(cs, autocommit=True)
        self.cur = self.conn.cursor()
        self.cur.fast_executemany = not args.no_fast

    def scalar(self, sql):
        return self.cur.execute(sql).fetchone()[0]

    def bulk(self, table, cols, rows, identity=False, chunk=20000):
        rows = list(rows) if not isinstance(rows, list) else rows
        n = len(rows)
        self.counts[table] = n
        if self.dry or n == 0:
            log(f"  {table}: {n:,} dòng (dry-run)" if self.dry else f"  {table}: 0 dòng")
            return
        sql = f"INSERT INTO {table} ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})"
        if identity:
            self.cur.execute(f"SET IDENTITY_INSERT {table} ON")
        t0 = time.time()
        for a in range(0, n, chunk):
            self.cur.executemany(sql, rows[a:a + chunk])
            if n > 200000 and (a // chunk) % 10 == 9:
                log(f"    {table}: {min(a + chunk, n):,}/{n:,}")
        if identity:
            self.cur.execute(f"SET IDENTITY_INSERT {table} OFF")
        log(f"  {table}: {n:,} dòng ({time.time() - t0:.1f}s)")


def main():
    args = parse_args()
    scale = args.scale
    rng = np.random.default_rng(args.seed)
    rnd = random.Random(args.seed)
    try:
        from faker import Faker
    except ImportError:
        sys.exit("Thiếu thư viện: pip install faker")
    fake = Faker("vi_VN")
    Faker.seed(args.seed)

    NDAYS = 365
    END = date.today() - timedelta(days=1)
    START = END - timedelta(days=NDAYS - 1)
    END_IDX = NDAYS - 1
    END_DT = datetime.combine(END, dtime(21, 0))
    NOW_STR = datetime.combine(date.today(), dtime(0, 0)).isoformat()
    log(f"Khoảng dữ liệu: {START} .. {END} ({NDAYS} ngày), scale={scale}")

    L = Loader(args)
    if not args.dry_run:
        if L.scalar("SELECT COUNT(*) FROM CHI_NHANH") > 0:
            sys.exit("Database đã có dữ liệu. Chạy lại 01_create_schema.sql để tạo DB trống rồi chạy lại script này.")
        try:
            L.cur.execute(f"ALTER DATABASE {args.database} SET RECOVERY SIMPLE")
        except Exception:
            pass
        dv_id = {r[1]: r[0] for r in L.cur.execute("SELECT ma_dv, ten_dv FROM DICH_VU").fetchall()}
    else:
        dv_id = {name: i + 1 for i, name in enumerate(SERVICES)}

    used_phone = set()

    def new_phone():
        while True:
            p = rnd.choice(PHONE_PREFIX) + "".join(rnd.choices("0123456789", k=7))
            if p not in used_phone:
                used_phone.add(p)
                return p

    # ---------------------------------------------------------------- chi nhánh, dịch vụ, cửa
    branches = []
    for i, (qh, tp) in enumerate(BRANCH_DEFS, start=1):
        branches.append((i, f"FitLife Hub {qh}", f"{rnd.randint(1, 300)} {rnd.choice(STREETS)}, {qh}",
                         tp, "028" + "".join(rnd.choices("0123456789", k=7)), "05:00:00", "22:00:00", "HOAT_DONG"))
    cn_dv = []
    for b in range(1, NB + 1):
        for s in SERVICES:
            if offered(s, b):
                cap = rnd.randint(*SVC_CAP[s]) if s in SVC_CAP else None
                cn_dv.append((b, dv_id[s], cap, "HOAT_DONG"))
    doors = []
    for b in range(1, NB + 1):
        for k in range(4):
            doors.append(((b - 1) * 4 + k + 1, b, f"Cổng {k + 1}", "CONG_QUAY" if k < 2 else "MAY_QUET_QR", "HOAT_DONG"))

    # ---------------------------------------------------------------- nhân viên, HLV, lịch sử công tác
    emp, hlv_rows, lsct = [], [], []
    staff = {b: defaultdict(list) for b in range(1, NB + 1)}
    pt_info = {}                       # nv -> (branch0, hire)
    nv_id = 0
    for b in range(1, NB + 1):
        for role, cnt in ROLE_COUNTS:
            for _ in range(cnt):
                nv_id += 1
                hire = START - timedelta(days=rnd.randint(40, 1800))
                lo, hi = SALARY[role]
                emp.append((nv_id, fake.name(), new_phone(), rnd.randint(lo * 10, hi * 10) * 100_000, hire.isoformat(), "DANG_LAM"))
                staff[b][role].append(nv_id)
                if role == "PT":
                    ratio = Decimal(f"{rnd.uniform(0.15, 0.35):.4f}")
                    hlv_rows.append((nv_id, rnd.choice(CHUYEN_MON),
                                     rnd.choice(CHUNG_CHI) if rnd.random() > 0.2 else None, ratio))
                    pt_info[nv_id] = (b, hire, ratio)
                else:
                    lsct.append([nv_id, b, role, hire, None, None])
    pt_ids = list(pt_info)
    transferred = set(rnd.sample(pt_ids, max(1, int(round(0.15 * len(pt_ids)))))) if pt_ids else set()
    pt_by_branch = {b: [] for b in range(1, NB + 1)}   # b -> [(nv, from_idx, to_idx)]
    OPEN = 10 ** 9
    for nv in pt_ids:
        b0, hire, _ = pt_info[nv]
        f_idx = (hire - START).days
        if nv in transferred:
            t_idx = rnd.randint(30, NDAYS - 31)
            tdate = START + timedelta(days=t_idx)
            b1 = rnd.choice([x for x in range(1, NB + 1) if x != b0])
            lsct.append([nv, b0, "PT", hire, tdate, "Điều chuyển công tác"])
            lsct.append([nv, b1, "PT", tdate, None, "Điều chuyển công tác"])
            pt_by_branch[b0].append((nv, f_idx, t_idx))
            pt_by_branch[b1].append((nv, t_idx, OPEN))
        else:
            lsct.append([nv, b0, "PT", hire, None, None])
            pt_by_branch[b0].append((nv, f_idx, OPEN))
    lsct_rows = [(i + 1, r[0], r[1], r[2], r[3].isoformat(), r[4].isoformat() if r[4] else None, r[5])
                 for i, r in enumerate(lsct)]

    # ---------------------------------------------------------------- sản phẩm, tồn kho
    loai_rows, sp_rows = [], []
    sp_id = 0
    for li, (cat, tmpl, v1, v2, pmin, pmax, unit) in enumerate(PRODUCT_CATS, start=1):
        loai_rows.append((li, cat))
        combos = rnd.sample(list(itertools.product(v1, v2)), PRODUCTS_PER_CAT)
        for c in combos:
            sp_id += 1
            sp_rows.append([sp_id, li, tmpl.format(*c), r1000(rnd.uniform(pmin, pmax)), unit, "DANG_BAN"])
    for i in rnd.sample(range(len(sp_rows)), 6):
        sp_rows[i][5] = "NGUNG_BAN"
    sellable = [i for i, r in enumerate(sp_rows) if r[5] == "DANG_BAN"]
    prod_price = {r[0]: r[3] for r in sp_rows}
    rnd.shuffle(sellable)
    prod_cum = make_cum([1.0 / (k + 1) ** 0.7 for k in range(len(sellable))])
    prod_ids = [sp_rows[i][0] for i in sellable]
    ton_rows = []
    for b in range(1, NB + 1):
        for r in sp_rows:
            muc = rnd.choice([10, 15, 20, 30])
            ton = rnd.randint(0, muc - 1) if rnd.random() < 0.08 else rnd.randint(muc, 400)
            ton_rows.append((b, r[0], ton, muc, (END_DT - timedelta(hours=rnd.randint(0, 600))).isoformat()))

    # ---------------------------------------------------------------- gói dịch vụ (bảng giá)
    goi_rows = [(j + 1, dv_id[p[1]], p[0], p[2], p[3], p[4], "DANG_BAN") for j, p in enumerate(PKGS)]
    pkg_cum = {}
    for b in range(1, NB + 1):
        pkg_cum[b] = make_cum([p[5] if offered(p[1], b) else 0 for p in PKGS])
    branch_cum = make_cum(BRANCH_W)

    # ---------------------------------------------------------------- hội viên
    N = max(60, int(30000 * scale))
    J = np.sort(rng.integers(-540, NDAYS, size=N))        # ngày đăng ký (chỉ số ngày so với START)
    elig = np.maximum(J, 0)
    wmem = rng.lognormal(0, 0.9, size=N)
    cumw = np.cumsum(wmem)
    home = rng.choice(NB, size=N, p=np.asarray(BRANCH_W) / sum(BRANCH_W)) + 1
    locked = rng.random(N) < 0.01
    used_cccd = set()
    mem_rows = []
    for i in range(N):
        jd = START + timedelta(days=int(J[i]))
        while True:
            c = rnd.choice(CCCD_PREFIX) + rnd.choice("0123") + f"{rnd.randint(70, 99):02d}" + "".join(rnd.choices("0123456789", k=6))
            if c not in used_cccd:
                used_cccd.add(c)
                break
        age = int(min(65, max(16, rng.normal(30, 9))))
        dob = jd - timedelta(days=age * 365 + rnd.randint(0, 364) + 1)
        mem_rows.append((i + 1, f"FL{i + 1:07d}", fake.name(), new_phone(),
                         f"member{i + 1}@example.com" if rnd.random() < 0.8 else None, c,
                         rnd.choices("MFO", weights=[48, 49, 3])[0], dob.isoformat(), jd.isoformat(),
                         "KHOA" if locked[i] else "HOAT_DONG"))
    log(f"Danh mục xong: {len(emp)} nhân viên ({len(hlv_rows)} HLV, {len(transferred)} PT điều chuyển), {N:,} hội viên")

    # ---------------------------------------------------------------- khung thời gian & mẫu hóa đơn
    def sample_secs(n):
        h = 5 + rng.choice(17, size=n, p=HOUR_P)
        s = h * 3600 + rng.integers(0, 3600, size=n)
        return np.minimum(s, 21 * 3600 + 1799)

    d_l, s_l, k_l, m_l = [], [], [], []
    for d in range(NDAYS):
        n_p = int(rng.poisson(480 * scale))
        n_s = int(rng.poisson(1000 * scale))
        k = int(np.searchsorted(elig, d, side="right"))
        n = n_p + n_s
        u = rng.random(n) * cumw[k - 1]
        mem = np.minimum(np.searchsorted(cumw, u, side="right"), k - 1)
        kind = np.concatenate([np.zeros(n_p, dtype=np.int8), np.ones(n_s, dtype=np.int8)])
        walk = (kind == 1) & (rng.random(n) < 0.30)
        mem = np.where(walk, -1, mem)
        d_l.append(np.full(n, d, dtype=np.int32)); s_l.append(sample_secs(n)); k_l.append(kind); m_l.append(mem)
    day_a = np.concatenate(d_l); sec_a = np.concatenate(s_l); kind_a = np.concatenate(k_l); mem_a = np.concatenate(m_l)
    order = np.lexsort((sec_a, day_a))
    day_a, sec_a, kind_a, mem_a = day_a[order], sec_a[order], kind_a[order], mem_a[order]
    NI = len(day_a)
    log(f"Sinh {NI:,} hóa đơn ...")

    # ---------------------------------------------------------------- hóa đơn, gói đã mua, thanh toán, điểm
    P_ID, P_HD, P_GOI, P_PRICE, P_BAT, P_HET, P_CON, P_ST, P_MEM, P_DAY, P_SVC, P_INVDT, P_SOBUOI = range(13)
    inv_rows, pkg_list, ct_rows, pay_rows, gdd = [], [], [], [], []
    spend_month = defaultdict(int)            # (hv, (y,m)) -> tiền
    spend_total = defaultdict(int)
    last_paid_day = {}
    rev = {}                                   # (cn, day) -> [so_hd, goi, sp]
    goi_month = {}                             # (goi, (y,m)) -> [sl, doanh thu]
    gwc = itertools.count(1)
    pay_id = 0
    method_cum = make_cum([35, 40, 25])
    METHODS = ["TIEN_MAT", "VNPAY", "THE"]

    def gw(meth):
        return f"{'VNP' if meth == 'VNPAY' else 'CRD'}{next(gwc):012d}"

    for i in range(NI):
        hd = i + 1
        d = int(day_a[i]); s = int(sec_a[i]); m = int(mem_a[i]); kind = int(kind_a[i])
        dt = datetime.combine(START + timedelta(days=d), dtime(0, 0)) + timedelta(seconds=s)
        if m >= 0 and rnd.random() < 0.88:
            b = int(home[m])
        else:
            b = pick(branch_cum, rnd.random()) + 1
        goi_lines, sp_lines = [], []
        if kind == 0:
            j = pick(pkg_cum[b], rnd.random())
            goi_lines.append(j)
            if rnd.random() < 0.05:
                j2 = pick(pkg_cum[b], rnd.random())
                if j2 != j:
                    goi_lines.append(j2)
        if kind == 1 or rnd.random() < 0.08:
            nl = rnd.choices([1, 2, 3], weights=[60, 30, 10])[0]
            seen = set()
            for _ in range(nl):
                pid = prod_ids[pick(prod_cum, rnd.random())]
                if pid not in seen:
                    seen.add(pid)
                    sp_lines.append((pid, rnd.choice([1, 1, 1, 2, 2, 3])))
        nv = rnd.choice(staff[b]["LE_TAN"] if goi_lines else staff[b]["NV_BAN_HANG"])
        goi_sum = sum(PKGS[j][4] for j in goi_lines)
        sp_sum = sum(q * prod_price[pid] for pid, q in sp_lines)
        giam = r1000(goi_sum * rnd.choice([5, 10, 15]) / 100.0) if (goi_lines and rnd.random() < 0.25) else 0
        tong = goi_sum + sp_sum
        tt = tong - giam
        rr = rnd.random()
        if d <= NDAYS - 2 and rr < 0.03:
            st = "DA_HUY"
        elif d >= NDAYS - 2 and rr > 0.95:
            st = "CHO_THANH_TOAN"
        else:
            st = "DA_THANH_TOAN"
        hv = m + 1 if m >= 0 else None
        inv_rows.append((hd, hv, nv, b, dt.isoformat(), tong, giam, tt, st))
        # --- dòng gói
        for j in goi_lines:
            nm, svc, months, sobuoi, price, _w = PKGS[j]
            bat = START + timedelta(days=d)
            het = add_months(bat, months) if months else bat + timedelta(days=30)
            con = sobuoi if svc == "PT 1-1" else (1 if svc == "Spa" else None)
            if st == "CHO_THANH_TOAN":
                ps = "CHO_KICH_HOAT"
            elif st == "DA_HUY":
                ps = "DA_HUY"
            else:
                ps = "HIEU_LUC" if het > END else "HET_HAN"
            pkg_list.append([len(pkg_list) + 1, hd, j + 1, price, bat, het, con, ps, m, d, svc, dt, sobuoi])
            if st == "DA_THANH_TOAN":
                key = (j + 1, (bat.year, bat.month))
                e = goi_month.setdefault(key, [0, 0]); e[0] += 1; e[1] += price
        for pid, q in sp_lines:
            ct_rows.append((hd, pid, q, prod_price[pid]))
        if st == "DA_THANH_TOAN":
            e = rev.setdefault((b, d), [0, 0, 0])
            e[0] += 1; e[1] += goi_sum - giam; e[2] += sp_sum
            if m >= 0:
                spend_month[(m, (dt.year, dt.month))] += tt
                spend_total[m] += tt
                last_paid_day[m] = d
        # --- thanh toán
        last_ok = None
        if st == "CHO_THANH_TOAN":
            if rnd.random() < 0.2:
                pay_id += 1
                pay_rows.append((pay_id, hd, "VNPAY", tt, gw("VNPAY"), (dt + timedelta(minutes=1)).isoformat(), "THAT_BAI"))
        else:
            t = dt + timedelta(minutes=rnd.randint(1, 8))
            meth = METHODS[pick(method_cum, rnd.random())]
            r = rnd.random()
            if r < 0.08 and meth != "TIEN_MAT":
                pay_id += 1
                pay_rows.append((pay_id, hd, meth, tt, gw(meth), t.isoformat(), "THAT_BAI"))
                t += timedelta(minutes=2)
            if 0.08 <= r < 0.20 and tt >= 2000:
                a = max(1000, min(tt - 1000, r1000(tt * rnd.uniform(0.4, 0.7))))
                m2 = METHODS[pick(method_cum, rnd.random())]
                pay_id += 1
                pay_rows.append((pay_id, hd, meth, a, gw(meth) if meth != "TIEN_MAT" else None, t.isoformat(), "THANH_CONG"))
                t += timedelta(minutes=1)
                pay_id += 1
                pay_rows.append((pay_id, hd, m2, tt - a, gw(m2) if m2 != "TIEN_MAT" else None, t.isoformat(), "THANH_CONG"))
            else:
                pay_id += 1
                pay_rows.append((pay_id, hd, meth, tt, gw(meth) if meth != "TIEN_MAT" else None, t.isoformat(), "THANH_CONG"))
            last_ok = t
            if st == "DA_HUY":
                pay_id += 1
                pay_rows.append((pay_id, hd, meth, tt, gw(meth) if meth != "TIEN_MAT" else None,
                                 (dt + timedelta(days=1, hours=1)).isoformat(), "HOAN_TIEN"))
        # --- điểm loyalty
        if hv is not None and st != "CHO_THANH_TOAN":
            pts = tt // 100000
            if pts > 0:
                gdd.append([hv, hd, "TICH", pts, last_ok.isoformat(), None])
                if st == "DA_HUY":
                    gdd.append([hv, hd, "HOAN_TICH", -pts, (dt + timedelta(days=1, hours=1)).isoformat(),
                                "Hoàn điểm do hủy hóa đơn"])
    log(f"  hóa đơn {len(inv_rows):,} | gói đã mua {len(pkg_list):,} | dòng SP {len(ct_rows):,} | thanh toán {len(pay_rows):,}")

    # ---------------------------------------------------------------- check-in
    NP = len(pkg_list)
    p_mem = np.array([p[P_MEM] for p in pkg_list], dtype=np.int64)
    p_day = np.array([p[P_DAY] for p in pkg_list], dtype=np.int64)
    p_het = np.array([(p[P_HET] - START).days for p in pkg_list], dtype=np.int64)
    p_svc = np.array([SVC_CODE[p[P_SVC]] for p in pkg_list], dtype=np.int64)
    p_paid = np.array([p[P_ST] in ("HIEU_LUC", "HET_HAN") for p in pkg_list])
    p_lock = np.zeros(NP, dtype=bool)
    has_m = p_mem >= 0
    p_lock[has_m] = locked[p_mem[has_m]]
    s_idx = p_day + 1
    e_idx = np.minimum(p_het, END_IDX)
    n_av = np.maximum(0, e_idx - s_idx + 1)
    ok = p_paid & ~p_lock & has_m
    rec_idx = np.flatnonzero(ok & (p_svc <= 2) & (n_av > 0))
    spa_idx = np.flatnonzero(ok & (p_svc == 4) & (n_av > 0))
    spa_use = spa_idx[rng.random(len(spa_idx)) < 0.85]
    spa_day = s_idx[spa_use] + np.floor(rng.random(len(spa_use)) * n_av[spa_use]).astype(np.int64)
    valid_target = int(10000 * NDAYS * scale * 0.975)
    rec_target = max(0, valid_target - len(spa_use))
    total_pairs = int(n_av[rec_idx].sum())
    p0 = min(1.0, rec_target * 1.12 / max(1, total_pairs))
    log(f"Sinh check-in: {len(rec_idx):,} gói định kỳ, {total_pairs:,} cặp (gói, ngày), p={p0:.3f}")

    out_pk, out_day = [], []
    pos = 0
    while pos < len(rec_idx):
        csum = np.cumsum(n_av[rec_idx[pos:]])
        cnt = max(1, int(np.searchsorted(csum, 3_000_000, side="right")))
        sub = rec_idx[pos:pos + cnt]
        nn = n_av[sub]
        tot = int(nn.sum())
        rep = np.repeat(np.arange(len(sub)), nn)
        starts = np.cumsum(nn) - nn
        off = np.arange(tot) - np.repeat(starts, nn)
        keep = rng.random(tot) < p0
        out_pk.append(sub[rep[keep]])
        out_day.append(s_idx[sub][rep[keep]] + off[keep])
        pos += cnt
    v_pk = np.concatenate(out_pk + [spa_use]) if out_pk else spa_use
    v_day = np.concatenate(out_day + [spa_day]) if out_day else spa_day
    v_spa = np.concatenate([np.zeros(len(v_pk) - len(spa_use), dtype=bool), np.ones(len(spa_use), dtype=bool)])
    # mỗi hội viên tối đa 1 lượt/ngày (BR05: không chồng lượt)
    key = p_mem[v_pk] * NDAYS + v_day
    perm = rng.permutation(len(key))
    _, first = np.unique(key[perm], return_index=True)
    sel = perm[first]
    v_pk, v_day, v_spa = v_pk[sel], v_day[sel], v_spa[sel]
    rec_pos = np.flatnonzero(~v_spa)
    if len(rec_pos) > rec_target:
        drop = rng.choice(rec_pos, len(rec_pos) - rec_target, replace=False)
        keepm = np.ones(len(v_pk), dtype=bool); keepm[drop] = False
        v_pk, v_day, v_spa = v_pk[keepm], v_day[keepm], v_spa[keepm]
    for pk in v_pk[v_spa].tolist():              # vé Spa đã dùng
        pkg_list[pk][P_CON] = 0
        pkg_list[pk][P_ST] = "HET_HAN"
    nv_ = len(v_pk)
    v_mem = p_mem[v_pk]
    v_svc = p_svc[v_pk]
    v_br = home[v_mem].copy()
    trav = rng.random(nv_) < 0.12
    for sv in range(5):
        lst = np.array([b for b in range(1, NB + 1) if offered(["Gym", "Yoga", "GroupX", "PT 1-1", "Spa"][sv], b)])
        isoff = np.zeros(NB + 1, dtype=bool); isoff[lst] = True
        need = (v_svc == sv) & (trav | ~isoff[v_br])
        c = int(need.sum())
        if c:
            v_br[need] = lst[rng.integers(0, len(lst), c)]
    v_sec = sample_secs(nv_)
    v_dur = rng.integers(40 * 60, 110 * 60, size=nv_)
    v_door = (v_br - 1) * 4 + 1 + rng.integers(0, 4, size=nv_)
    v_pkid = np.array([pkg_list[k][P_ID] for k in v_pk], dtype=np.int64) if nv_ else np.zeros(0, dtype=np.int64)
    # lượt quét bị từ chối (~2,5%)
    n_rej = int(nv_ * 0.025 / 0.975)
    r_day = rng.integers(0, NDAYS, size=n_rej)
    kk = np.searchsorted(elig, r_day, side="right")
    r_mem = np.floor(rng.random(n_rej) * kk).astype(np.int64)
    r_br = rng.choice(NB, size=n_rej, p=np.asarray(BRANCH_W) / sum(BRANCH_W)) + 1
    ci_day = np.concatenate([v_day, r_day])
    ci_sec = np.concatenate([v_sec, sample_secs(n_rej)])
    ci_mem = np.concatenate([v_mem, r_mem])
    ci_br = np.concatenate([v_br, r_br])
    ci_door = np.concatenate([v_door, (r_br - 1) * 4 + 1 + rng.integers(0, 4, size=n_rej)])
    ci_pk = np.concatenate([v_pkid, np.full(n_rej, -1, dtype=np.int64)])
    ci_dur = np.concatenate([v_dur, np.zeros(n_rej, dtype=np.int64)])
    ci_valid = np.concatenate([np.ones(nv_, dtype=bool), np.zeros(n_rej, dtype=bool)])
    o = np.lexsort((ci_sec, ci_day))
    ci_day, ci_sec, ci_mem, ci_br, ci_door, ci_pk, ci_dur, ci_valid = [a[o] for a in
        (ci_day, ci_sec, ci_mem, ci_br, ci_door, ci_pk, ci_dur, ci_valid)]
    ci_end = np.minimum(ci_sec + ci_dur, 22 * 3600)
    ci_null = (~ci_valid) | ((ci_day == END_IDX) & (rng.random(len(ci_day)) < 0.03))
    NC = len(ci_day)
    log(f"  check-in: {NC:,} (hợp lệ {nv_:,}, từ chối {n_rej:,}); tỷ lệ 17h-20h = "
        f"{((ci_sec >= 17 * 3600) & (ci_sec < 20 * 3600)).mean():.1%}")

    # ---------------------------------------------------------------- lịch hẹn PT
    sessions = []
    slot_hlv, slot_hv = set(), set()
    commission = {}                            # (hlv, cn, (y,m)) -> [so_buoi, tien]
    ratio_of = {k: float(v[2]) for k, v in pt_info.items()}
    khung_vals = list(range(1, 18))
    for p in pkg_list:
        if p[P_SVC] != "PT 1-1" or p[P_ST] not in ("HIEU_LUC", "HET_HAN") or p[P_MEM] < 0:
            continue
        s0 = p[P_DAY] + 1
        het_idx = (p[P_HET] - START).days
        e0 = min(het_idx, END_IDX)
        if e0 < s0:
            continue
        validity = (p[P_HET] - p[P_BAT]).days
        f = min(1.0, (e0 - p[P_DAY]) / (0.75 * validity))
        n = min(p[P_SOBUOI], int(round(p[P_SOBUOI] * f * rnd.uniform(0.5, 1.0))))
        hi = min(het_idx, END_IDX + 14)
        used = 0
        for _ in range(n):
            cancelled = False
            d_i = rnd.randint(s0, hi)
            past = d_i <= END_IDX
            if past:
                cancelled = rnd.random() < 0.12
            placed = None
            for _try in range(15):
                d_i = rnd.randint(s0, hi)
                if (d_i <= END_IDX) != past:
                    continue
                b = int(home[p[P_MEM]]) if rnd.random() < 0.9 else pick(branch_cum, rnd.random()) + 1
                lst = pt_by_branch[b]
                cand = None
                for _k in range(12):
                    x = lst[rnd.randrange(len(lst))]
                    if x[1] <= d_i < x[2]:
                        cand = x[0]; break
                if cand is None:
                    continue
                kh = rnd.choices(khung_vals, weights=HOUR_W)[0]
                if not cancelled and ((cand, d_i, kh) in slot_hlv or (p[P_MEM], d_i, kh) in slot_hv):
                    continue
                placed = (cand, b, d_i, kh)
                break
            if placed is None:
                continue
            hlv, cn, d_i, kh = placed
            if not cancelled:
                slot_hlv.add((hlv, d_i, kh)); slot_hv.add((p[P_MEM], d_i, kh))
                used += 1
            if cancelled:
                stt = "DA_HUY"
            elif past:
                stt = "DA_HOAN_THANH"
            else:
                stt = "DA_DAT"
            k_ = rnd.randint(1, 10)
            cand_dt = datetime.combine(START + timedelta(days=d_i - k_), dtime(rnd.randint(8, 21), rnd.randint(0, 59)))
            nd = max(min(cand_dt, END_DT), p[P_INVDT] + timedelta(minutes=10))
            rating = nx = reason = None
            if stt == "DA_HUY":
                reason = rnd.choice(CANCEL_REASONS)
            elif stt == "DA_HOAN_THANH":
                if rnd.random() < 0.55:
                    rating = rnd.choices([1, 2, 3, 4, 5], weights=[2, 4, 14, 35, 45])[0]
                    nx = rnd.choice(REVIEWS) if rnd.random() < 0.25 else None
                ck = (hlv, cn, (START + timedelta(days=d_i)).year * 100 + (START + timedelta(days=d_i)).month)
                e = commission.setdefault(ck, [0, 0.0]); e[0] += 1
                e[1] += p[P_PRICE] / p[P_SOBUOI] * ratio_of[hlv]
            sessions.append((nd, p[P_MEM] + 1, hlv, cn, p[P_ID], (START + timedelta(days=d_i)).isoformat(),
                             kh, stt, reason, rating, nx))
        if p[P_CON] is not None:
            p[P_CON] = p[P_SOBUOI] - used
    sessions.sort(key=lambda r: r[0])
    lich_rows = [(i + 1, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[0].isoformat(), r[8], r[9], r[10])
                 for i, r in enumerate(sessions)]
    log(f"  lịch hẹn PT: {len(lich_rows):,}")

    # ---------------------------------------------------------------- sổ điểm, tài khoản loyalty
    for _ in range(int(400 * scale) + 1):
        mm = rnd.randrange(N)
        d_ = max(int(elig[mm]), 0)
        dd = START + timedelta(days=rnd.randint(d_, END_IDX))
        gdd.append([mm + 1, None, "DIEU_CHINH", rnd.choice([50, 100, 200]),
                    datetime.combine(dd, dtime(10, 0)).isoformat(), "Tặng điểm sự kiện"])
    bal = defaultdict(int)
    for g in gdd:
        bal[g[0]] += g[3]
    for hv_, v in list(bal.items()):
        if v >= 100 and rnd.random() < 0.04:
            red = -rnd.randint(10, min(v, 60))
            dd = START + timedelta(days=rnd.randint(int(max(elig[hv_ - 1], 0)), END_IDX))
            gdd.append([hv_, None, "DOI_DIEM", red, datetime.combine(dd, dtime(15, 0)).isoformat(), "Đổi điểm lấy quà"])
            bal[hv_] += red
    gdd.sort(key=lambda g: g[4])
    gdd_rows = [(i + 1, g[0], g[1], g[2], g[3], g[4], g[5]) for i, g in enumerate(gdd)]
    tk_rows = []
    for i in range(N):
        sp_ = spend_total.get(i, 0)
        hang = 3 if sp_ >= 50_000_000 else (2 if sp_ >= 20_000_000 else 1)
        xet = (START + timedelta(days=last_paid_day[i])).isoformat() if (hang > 1 and i in last_paid_day) else None
        tk_rows.append((i + 1, hang, bal.get(i + 1, 0), sp_, xet))
    hang_cnt = np.bincount([r[1] for r in tk_rows], minlength=4)[1:]
    log(f"  phân bổ hạng: Silver {hang_cnt[0]:,} | Gold {hang_cnt[1]:,} | Platinum {hang_cnt[2]:,}")

    # ---------------------------------------------------------------- bảng dẫn xuất
    qvc = {}
    for p in pkg_list:
        if p[P_ST] == "HIEU_LUC" and p[P_MEM] >= 0 and p[P_SVC] in ("Gym", "Yoga", "GroupX", "Spa"):
            k_ = (p[P_MEM] + 1, dv_id[p[P_SVC]])
            if k_ not in qvc or p[P_HET] > qvc[k_][0]:
                qvc[k_] = (p[P_HET], p[P_ID], p[P_CON] if p[P_SVC] == "Spa" else None)
    qvc_rows = [(k[0], k[1], v[0].isoformat(), v[1], v[2], NOW_STR) for k, v in qvc.items()]
    th_ngay = [(b, (START + timedelta(days=d)).isoformat(), v[0], v[1], v[2]) for (b, d), v in sorted(rev.items())]
    th_goi = [(g, date(ym[0], ym[1], 1).isoformat(), v[0], v[1]) for (g, ym), v in sorted(goi_month.items())]
    vm = ci_valid
    h0 = ci_sec[vm] // 3600
    h1 = np.where(ci_null[vm], h0, ci_end[vm] // 3600)
    base_key = (ci_br[vm] - 1) * NDAYS * 24 + ci_day[vm] * 24
    size = NB * NDAYS * 24
    vao = np.bincount(base_key + h0, minlength=size)
    present = np.zeros(size, dtype=np.int64)
    for k_ in range(3):
        mk = (h0 + k_) <= h1
        present += np.bincount(base_key[mk] + h0[mk] + k_, minlength=size)
    th_gio = []
    for kx in np.flatnonzero(present):
        b = kx // (NDAYS * 24); rem = kx % (NDAYS * 24)
        th_gio.append((int(b) + 1, (START + timedelta(days=int(rem // 24))).isoformat(), int(rem % 24), int(vao[kx]), int(present[kx])))
    ct_thang = [(hv_ + 1, date(ym[0], ym[1], 1).isoformat(), v) for (hv_, ym), v in sorted(spend_month.items())]
    hh_rows = []
    cur_ym = END.year * 100 + END.month
    for (hlv, cn, ym), (cnt, tien) in sorted(commission.items()):
        y, mth = divmod(ym, 100)
        chot = None if ym >= cur_ym else datetime.combine(add_months(date(y, mth, 1), 1), dtime(9, 0)).isoformat()
        hh_rows.append((hlv, cn, date(y, mth, 1).isoformat(), cnt, int(round(tien)), chot))

    # ---------------------------------------------------------------- tự kiểm tra (trong bộ nhớ)
    assert sum(r[7] for r in inv_rows if r[8] == "DA_THANH_TOAN") == sum(v[1] + v[2] for v in rev.values()), "doanh thu ngày lệch"
    assert all(r[7] > 0 for r in inv_rows), "hóa đơn có thanh toán = 0"
    assert all(g[3] != 0 for g in gdd), "giao dịch điểm = 0"
    assert all(p[P_CON] is None or p[P_CON] >= 0 for p in pkg_list), "số buổi còn lại âm"
    log("Tự kiểm tra bộ nhớ: OK")

    # ---------------------------------------------------------------- ghi vào DB (đúng thứ tự khóa ngoại)
    log("Ghi dữ liệu vào SQL Server ..." if not args.dry_run else "Dry-run: không ghi DB")
    L.bulk("CHI_NHANH", ["ma_cn", "ten_cn", "dia_chi", "thanh_pho", "sdt", "gio_mo", "gio_dong", "trang_thai"], branches, True)
    L.bulk("CN_DICH_VU", ["ma_cn", "ma_dv", "suc_chua", "trang_thai"], cn_dv)
    L.bulk("CUA_KIEM_SOAT", ["ma_cua", "ma_cn", "vi_tri", "loai_thiet_bi", "trang_thai"], doors, True)
    L.bulk("NHAN_VIEN", ["ma_nv", "ho_ten", "sdt", "luong_co_ban", "ngay_vao_lam", "trang_thai"], emp, True)
    L.bulk("HUAN_LUYEN_VIEN", ["ma_nv", "chuyen_mon", "chung_chi", "ty_le_hoa_hong"], hlv_rows)
    L.bulk("LICH_SU_CONG_TAC", ["ma_ls", "ma_nv", "ma_cn", "chuc_vu", "tu_ngay", "den_ngay", "ly_do"], lsct_rows, True)
    L.bulk("HOI_VIEN", ["ma_hv", "ma_the", "ho_ten", "sdt", "email", "cccd", "gioi_tinh", "ngay_sinh", "ngay_dang_ky", "trang_thai"], mem_rows, True)
    L.bulk("LOAI_SAN_PHAM", ["ma_loai", "ten_loai"], loai_rows, True)
    L.bulk("SAN_PHAM", ["ma_sp", "ma_loai", "ten_sp", "gia_ban", "don_vi_tinh", "trang_thai"], [tuple(r) for r in sp_rows], True)
    L.bulk("TON_KHO", ["ma_cn", "ma_sp", "so_luong_ton", "muc_ton_toi_thieu", "ngay_cap_nhat"], ton_rows)
    L.bulk("GOI_DICH_VU", ["ma_goi", "ma_dv", "ten_goi", "thoi_han_thang", "so_buoi_pt", "gia_tien", "trang_thai_ban"], goi_rows, True)
    L.bulk("HOA_DON", ["ma_hd", "ma_hv", "ma_nv_lap", "ma_cn", "ngay_lap", "tong_tien", "giam_gia", "thanh_toan", "trang_thai"], inv_rows, True)
    L.bulk("GOI_DA_MUA", ["ma_goi_mua", "ma_hd", "ma_goi", "don_gia", "ngay_bat_dau", "ngay_het_han", "so_buoi_con_lai", "trang_thai"],
           [(p[P_ID], p[P_HD], p[P_GOI], p[P_PRICE], p[P_BAT].isoformat(), p[P_HET].isoformat(), p[P_CON], p[P_ST]) for p in pkg_list], True)
    L.bulk("CT_HD_SAN_PHAM", ["ma_hd", "ma_sp", "so_luong", "don_gia"], ct_rows)
    L.bulk("THANH_TOAN", ["ma_tt", "ma_hd", "hinh_thuc", "so_tien", "ma_giao_dich_cong", "thoi_diem", "trang_thai"], pay_rows, True)
    L.bulk("GIAO_DICH_DIEM", ["ma_gd", "ma_hv", "ma_hd", "loai_gd", "so_diem", "ngay_gd", "ghi_chu"], gdd_rows, True)
    L.bulk("TAI_KHOAN_LOYALTY", ["ma_hv", "ma_hang", "diem_hien_co", "tong_chi_tieu_12t", "ngay_xet_hang"], tk_rows)
    L.bulk("LICH_HEN_PT", ["ma_lich", "ma_hv", "ma_hlv", "ma_cn", "ma_goi_mua", "ngay_tap", "ma_khung_gio", "trang_thai",
                           "ngay_dat", "ly_do_huy", "diem_danh_gia", "nhan_xet"], lich_rows, True)

    # CHECK_IN: bảng lớn nhất, ghi theo lô từ mảng numpy
    base64 = np.datetime64(START.isoformat(), "s")

    def fmt(dayv, secv):
        return (base64 + dayv.astype("timedelta64[D]") + secv.astype("timedelta64[s]")).astype(str)

    L.counts["CHECK_IN"] = NC
    if args.dry_run:
        log(f"  CHECK_IN: {NC:,} dòng (dry-run)")
    else:
        sql = "INSERT INTO CHECK_IN (ma_checkin,ma_hv,ma_cua,ma_cn,ma_goi_mua,tg_vao,tg_ra,ket_qua) VALUES (?,?,?,?,?,?,?,?)"
        L.cur.execute("SET IDENTITY_INSERT CHECK_IN ON")
        t0 = time.time(); CH = 50000
        for a in range(0, NC, CH):
            z = slice(a, min(a + CH, NC))
            vao_s = fmt(ci_day[z], ci_sec[z]).tolist()
            ra_s = fmt(ci_day[z], ci_end[z]).astype(object)
            ra_s[ci_null[z]] = None
            pkc = ci_pk[z].astype(object)
            pkc[ci_pk[z] < 0] = None
            res = np.where(ci_valid[z], "HOP_LE", "TU_CHOI").tolist()
            ids = np.arange(z.start + 1, z.stop + 1).tolist()
            L.cur.executemany(sql, list(zip(ids, (ci_mem[z] + 1).tolist(), ci_door[z].tolist(), ci_br[z].tolist(),
                                            pkc.tolist(), vao_s, ra_s.tolist(), res)))
            if (a // CH) % 10 == 9:
                log(f"    CHECK_IN: {z.stop:,}/{NC:,} ({time.time() - t0:.0f}s)")
        L.cur.execute("SET IDENTITY_INSERT CHECK_IN OFF")
        log(f"  CHECK_IN: {NC:,} dòng ({time.time() - t0:.0f}s)")

    L.bulk("QUYEN_VAO_CONG", ["ma_hv", "ma_dv", "ngay_het_han", "ma_goi_mua", "so_luot_con_lai", "cap_nhat_luc"], qvc_rows)
    L.bulk("TH_DOANH_THU_NGAY", ["ma_cn", "ngay", "so_hoa_don", "doanh_thu_goi", "doanh_thu_san_pham"], th_ngay)
    L.bulk("TH_DOANH_THU_GOI_THANG", ["ma_goi", "thang", "so_luong_ban", "doanh_thu"], th_goi)
    L.bulk("TH_LAP_DAY_GIO", ["ma_cn", "ngay", "gio", "so_luot_vao", "so_nguoi_co_mat"], th_gio)
    L.bulk("CHI_TIEU_THANG_HV", ["ma_hv", "thang", "tong_chi_tieu"], ct_thang)
    L.bulk("HOA_HONG_HLV_THANG", ["ma_hlv", "ma_cn", "thang", "so_buoi_hoan_thanh", "tong_hoa_hong", "ngay_chot"], hh_rows)

    log("Tổng kết số dòng:")
    for k, v in L.counts.items():
        log(f"  {k:<24}{v:>12,}")
    if not args.dry_run:
        log("Cập nhật thống kê ...")
        L.cur.execute("EXEC sp_updatestats")
    log("HOÀN TẤT.")


if __name__ == "__main__":
    main()
