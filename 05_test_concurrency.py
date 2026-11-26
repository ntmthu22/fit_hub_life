#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FitLife Hub - CSC12002 - Script 05: kiểm chứng ĐỒNG THỜI cho S1 và S2 (cần nhiều kết nối song song).

  python 05_test_concurrency.py overbook --mode naive   # S2 TRƯỚC: bỏ UNIQUE, kiểm tra-rồi-ghi  => có lịch trùng
  python 05_test_concurrency.py overbook --mode safe    # S2 SAU : sp_DatLichPT + UNIQUE có lọc => 0 lịch trùng
  python 05_test_concurrency.py checkin --threads 50 --requests 10000
                                                        # S1: p50/p95/p99 khi 50 kết nối cùng check-in

Tùy chọn kết nối giống 02_generate_data.py: --server, --database, --user, --password (hoặc FITLIFE_PWD).
Cần: pip install pyodbc
Lưu ý: chế độ checkin ghi ~10.000 lượt check-in "hôm nay"; script tự dọn (tạm tắt trigger chặn xóa RB40)
       trừ khi bạn thêm --keep.
"""
import argparse
import os
import random
import statistics
import sys
import threading
import time
from datetime import date, datetime, timedelta

import pyodbc


def parse_args():
    ap = argparse.ArgumentParser(description="Kiểm chứng đồng thời FitLifeHub")
    ap.add_argument("kich_ban", choices=["overbook", "checkin", "spa_checkin", "payment"])
    ap.add_argument("--mode", choices=["naive", "safe"], default="safe")
    ap.add_argument("--threads", type=int, default=50)
    ap.add_argument("--requests", type=int, default=10000)
    ap.add_argument("--keep", action="store_true", help="checkin: không dọn các lượt đã ghi")
    ap.add_argument("--server", default=os.environ.get("FITLIFE_SERVER", "localhost"))
    ap.add_argument("--database", default="FitLifeHub")
    ap.add_argument("--user", default=None)
    ap.add_argument("--password", default=os.environ.get("FITLIFE_PWD"))
    ap.add_argument("--driver", default=None)
    return ap.parse_args()


def conn_string(a):
    drv = a.driver
    if not drv:
        c = [d for d in pyodbc.drivers() if "SQL Server" in d]
        odbc = sorted([d for d in c if d.startswith("ODBC Driver")], reverse=True)
        drv = (odbc or c or [None])[0]
        if not drv:
            sys.exit("Không tìm thấy ODBC driver cho SQL Server (cài ODBC Driver 17/18).")
    cs = f"DRIVER={{{drv}}};SERVER={a.server};DATABASE={a.database};TrustServerCertificate=yes;"
    cs += f"UID={a.user};PWD={a.password};" if a.user else "Trusted_Connection=yes;"
    return cs


def connect(cs):
    return pyodbc.connect(cs, autocommit=True)


# ---------------------------------------------------------------------------
# S2: overbooking
# ---------------------------------------------------------------------------
def overbook(a, cs):
    n = a.threads
    c = connect(cs)
    cur = c.cursor()
    ngay = date.today() + timedelta(days=3)
    khung = 14                                        # khung giờ 18:00-19:00
    hlv = cur.execute("""
        SELECT TOP (1) ma_nv FROM dbo.LICH_SU_CONG_TAC
        WHERE chuc_vu='PT' AND den_ngay IS NULL ORDER BY NEWID()""").fetchone()[0]
    rows = cur.execute(f"""
        SELECT TOP ({n}) h.ma_hv, g.ma_goi_mua
        FROM dbo.GOI_DA_MUA g
        JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd
        JOIN dbo.HOI_VIEN v ON v.ma_hv = h.ma_hv AND v.trang_thai = 'HOAT_DONG'
        JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
        JOIN dbo.DICH_VU dv ON dv.ma_dv = d.ma_dv AND dv.nhom_dv = 'PT'
        WHERE g.trang_thai = 'HIEU_LUC' AND g.so_buoi_con_lai > 0
          AND ? BETWEEN g.ngay_bat_dau AND g.ngay_het_han AND h.ma_hv IS NOT NULL
        ORDER BY NEWID()""", ngay).fetchall()
    if len(rows) < n:
        n = len(rows)
        print(f"Chỉ tìm được {n} hội viên có gói PT hợp lệ; chạy với {n} luồng")
    if n < 2:
        sys.exit("Không đủ hội viên có gói PT hiệu lực để thử.")
    print(f"HLV {hlv}, ngày {ngay}, khung {khung}: {n} hội viên cùng đặt MỘT khung giờ")

    dropped = False
    if a.mode == "naive":
        print("Bỏ hai chỉ mục UNIQUE có lọc (mô phỏng thiết kế cũ) ...")
        cur.execute("DROP INDEX IF EXISTS UX_LHPT_hlv_khung ON dbo.LICH_HEN_PT")
        cur.execute("DROP INDEX IF EXISTS UX_LHPT_hv_khung ON dbo.LICH_HEN_PT")
        dropped = True

    barrier = threading.Barrier(n + 1)
    res = {"ok": 0, "da_co": 0, "khac": 0}
    ds_ok = []
    errs = []
    lock = threading.Lock()

    def worker(hv, gm):
        cn = connect(cs)
        cu = cn.cursor()
        try:
            barrier.wait()
            if a.mode == "naive":
                cu.execute("EXEC dbo.sp_DatLichPT_Naive ?, ?, ?, ?, ?", hv, gm, hlv, ngay, khung)
            else:
                cu.execute("EXEC dbo.sp_DatLichPT @ma_hv=?, @ma_goi_mua=?, @ma_hlv=?, @ngay_tap=?, @ma_khung_gio=?",
                           hv, gm, hlv, ngay, khung)
                while cu.nextset():
                    pass
            with lock:
                res["ok"] += 1
                ds_ok.append((hv, gm))
        except pyodbc.Error as e:
            msg = str(e)
            with lock:
                if "50016" in msg or "50099" in msg or "đã có người đặt" in msg:
                    res["da_co"] += 1
                else:
                    res["khac"] += 1
                    errs.append(msg[:160])
        finally:
            cn.close()

    ts = [threading.Thread(target=worker, args=r) for r in rows[:n]]
    for t in ts:
        t.start()
    barrier.wait()
    t0 = time.time()
    for t in ts:
        t.join()
    dt = time.time() - t0

    dup = cur.execute("""
        SELECT COUNT(*) FROM dbo.LICH_HEN_PT
        WHERE ma_hlv=? AND ngay_tap=? AND ma_khung_gio=? AND trang_thai<>'DA_HUY'""", hlv, ngay, khung).fetchone()[0]
    print("\n=== KẾT QUẢ ===")
    print(f"Chế độ: {a.mode} | {n} yêu cầu đồng thời trong {dt:.2f}s")
    print(f"  Đặt thành công (theo thủ tục)      : {res['ok']}")
    print(f"  Bị từ chối 'khung giờ đã có người' : {res['da_co']}")
    print(f"  Lỗi khác                           : {res['khac']}")
    print(f"  Số lịch HIỆU LỰC trong DB cho khung giờ này: {dup}  (đúng phải là 1)")
    if dup > 1:
        print(f"  => OVERBOOKING: {dup} hội viên cùng giữ một khung giờ của một HLV")
    elif dup == 1:
        print("  => Không có overbooking")
    for e in errs[:3]:
        print("  lỗi:", e)

    # dọn dữ liệu thử
    print("\nDọn dữ liệu thử ...")
    try:
        if a.mode == "naive":
            cur.execute("""UPDATE dbo.LICH_HEN_PT SET trang_thai='DA_HUY', ly_do_huy=N'test đồng thời'
                           WHERE ma_hlv=? AND ngay_tap=? AND ma_khung_gio=? AND trang_thai='DA_DAT'""", hlv, ngay, khung)
        else:
            for hv, gm in ds_ok:
                lich = cur.execute("""SELECT ma_lich FROM dbo.LICH_HEN_PT
                                      WHERE ma_hv=? AND ma_goi_mua=? AND ngay_tap=? AND ma_khung_gio=? AND trang_thai='DA_DAT'""",
                                   hv, gm, ngay, khung).fetchone()
                if lich:
                    cur.execute("EXEC dbo.sp_HuyLichPT @ma_lich=?, @ly_do=N'test đồng thời'", lich[0])
    finally:
        if dropped:
            print("Tạo lại hai chỉ mục UNIQUE có lọc (RB12) ...")
            cur.execute("""CREATE UNIQUE INDEX UX_LHPT_hlv_khung ON dbo.LICH_HEN_PT (ma_hlv, ngay_tap, ma_khung_gio)
                           WHERE trang_thai <> 'DA_HUY'""")
            cur.execute("""CREATE UNIQUE INDEX UX_LHPT_hv_khung ON dbo.LICH_HEN_PT (ma_hv, ngay_tap, ma_khung_gio)
                           WHERE trang_thai <> 'DA_HUY'""")
    c.close()
    print("Xong.")


# ---------------------------------------------------------------------------
# S1: check-in đồng thời
# ---------------------------------------------------------------------------
def checkin(a, cs):
    c = connect(cs)
    cur = c.cursor()
    need = a.requests
    # chỉ dùng hội viên có quyền định kỳ để không trừ lượt vé Spa
    cards = [r[0] for r in cur.execute(f"""
        SELECT TOP ({min(need, 30000)}) hv.ma_the
        FROM dbo.QUYEN_VAO_CONG q JOIN dbo.HOI_VIEN hv ON hv.ma_hv = q.ma_hv
        WHERE q.so_luot_con_lai IS NULL AND q.ngay_het_han >= CAST(SYSDATETIME() AS DATE) AND hv.trang_thai = 'HOAT_DONG'
        ORDER BY NEWID()""").fetchall()]
    if not cards:
        sys.exit("Không có hội viên nào còn quyền vào cổng định kỳ.")
    reqs = [random.choice(cards) for _ in range(need)]
    doors = [1, 2, 3, 4]                      # 4 cửa của chi nhánh 1
    t_start = datetime.now().replace(microsecond=0)
    lat = []
    rej = [0]
    lock = threading.Lock()
    idx = [0]
    barrier = threading.Barrier(a.threads + 1)

    def worker():
        cn = connect(cs)
        cu = cn.cursor()
        barrier.wait()
        while True:
            with lock:
                i = idx[0]
                if i >= len(reqs):
                    break
                idx[0] += 1
            t0 = time.perf_counter()
            try:
                cu.execute("EXEC dbo.sp_CheckIn @ma_the=?, @ma_cua=?", reqs[i], random.choice(doors))
                row = cu.fetchone()
                if row and row[0] == "TU_CHOI":
                    with lock:
                        rej[0] += 1
            except pyodbc.Error:
                with lock:
                    rej[0] += 1
            ms = (time.perf_counter() - t0) * 1000
            with lock:
                lat.append(ms)
        cn.close()

    ts = [threading.Thread(target=worker) for _ in range(a.threads)]
    for t in ts:
        t.start()
    barrier.wait()
    t0 = time.time()
    for t in ts:
        t.join()
    dt = time.time() - t0
    lat.sort()

    def pct(p):
        return lat[min(len(lat) - 1, int(len(lat) * p / 100))]

    print("\n=== KẾT QUẢ CHECK-IN ĐỒNG THỜI ===")
    print(f"{len(lat):,} lượt, {a.threads} kết nối, {dt:.1f}s  =>  {len(lat) / dt:,.0f} lượt/giây (~{len(lat) / dt * 3600:,.0f} lượt/giờ)")
    print(f"Độ trễ (ms): trung bình {statistics.mean(lat):.1f} | p50 {pct(50):.1f} | p95 {pct(95):.1f} | p99 {pct(99):.1f} | max {lat[-1]:.1f}")
    print(f"Từ chối/lỗi: {rej[0]}")
    print(f"Chỉ tiêu < 50 ms (p95): {'ĐẠT' if pct(95) < 50 else 'CHƯA ĐẠT'}")

    if not a.keep:
        print("\nDọn các lượt check-in vừa ghi ...")
        cur.execute("ALTER TABLE dbo.CHECK_IN DISABLE TRIGGER trg_CHECK_IN_nodel")
        try:
            n = cur.execute("DELETE FROM dbo.CHECK_IN WHERE tg_vao >= ?", t_start).rowcount
            print(f"Đã xóa {n:,} lượt thử.")
        finally:
            cur.execute("ALTER TABLE dbo.CHECK_IN ENABLE TRIGGER trg_CHECK_IN_nodel")
    c.close()


# ---------------------------------------------------------------------------
# Kiểm chứng đồng thời bổ sung: vé Spa lẻ (RB35) và thanh toán hóa đơn (RB26)
# ---------------------------------------------------------------------------
def spa_checkin(a, cs):
    """Nhiều luồng cùng quét 1 vé Spa lẻ (1 lượt): chỉ đúng 1 lượt HOP_LE, còn lại TU_CHOI."""
    n = max(2, min(a.threads, 20))
    c = connect(cs)
    cur = c.cursor()
    row = cur.execute("""
        SELECT TOP (1) hv.ma_the, q.ma_goi_mua, h.ma_cn
        FROM dbo.QUYEN_VAO_CONG q
        JOIN dbo.HOI_VIEN hv ON hv.ma_hv = q.ma_hv AND hv.trang_thai = 'HOAT_DONG'
        JOIN dbo.GOI_DA_MUA g ON g.ma_goi_mua = q.ma_goi_mua AND g.trang_thai = 'HIEU_LUC'
        JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd
        WHERE q.so_luot_con_lai = 1 AND q.ngay_het_han >= CAST(SYSDATETIME() AS DATE)
        ORDER BY NEWID()""").fetchone()
    if not row:
        sys.exit("Không tìm thấy hội viên nào có vé Spa lẻ còn 1 lượt.")
    ma_the, ma_goi_mua, ma_cn = row
    cua = cur.execute("SELECT TOP (1) ma_cua FROM dbo.CUA_KIEM_SOAT WHERE ma_cn=? AND trang_thai='HOAT_DONG'", ma_cn).fetchone()[0]
    t_start = datetime.now().replace(microsecond=0)
    barrier = threading.Barrier(n + 1)
    res = {"ok": 0, "rej": 0, "err": 0}
    lock = threading.Lock()

    def worker():
        cn = connect(cs)
        cu = cn.cursor()
        try:
            barrier.wait()
            cu.execute("EXEC dbo.sp_CheckIn @ma_the=?, @ma_cua=?", ma_the, cua)
            r = cu.fetchone()
            with lock:
                if r and r[0] == "HOP_LE":
                    res["ok"] += 1
                else:
                    res["rej"] += 1
        except pyodbc.Error:
            with lock:
                res["err"] += 1
        finally:
            cn.close()

    ts = [threading.Thread(target=worker) for _ in range(n)]
    for t in ts:
        t.start()
    barrier.wait()
    for t in ts:
        t.join()
    print(f"Vé Spa #{ma_goi_mua} ({ma_the}), {n} luồng: HOP_LE={res['ok']} (đúng=1), TU_CHOI={res['rej']}, Lỗi={res['err']}")
    if not a.keep:
        cur.execute("ALTER TABLE dbo.CHECK_IN DISABLE TRIGGER trg_CHECK_IN_nodel")
        try:
            cur.execute("DELETE FROM dbo.CHECK_IN WHERE tg_vao >= ? AND ma_hv = (SELECT ma_hv FROM dbo.HOI_VIEN WHERE ma_the=?)", t_start, ma_the)
            cur.execute("UPDATE dbo.GOI_DA_MUA SET so_buoi_con_lai=1, trang_thai='HIEU_LUC' WHERE ma_goi_mua=?", ma_goi_mua)
        finally:
            cur.execute("ALTER TABLE dbo.CHECK_IN ENABLE TRIGGER trg_CHECK_IN_nodel")
    c.close()


def payment(a, cs):
    """Nhiều luồng cùng thanh toán đủ 1 hóa đơn CHO_THANH_TOAN: chỉ đúng 1 luồng thành công."""
    n = max(2, min(a.threads, 20))
    c = connect(cs)
    cur = c.cursor()
    row = cur.execute("""
        SELECT TOP (1) h.ma_hd, h.thanh_toan
        FROM dbo.HOA_DON h
        WHERE h.trang_thai = 'CHO_THANH_TOAN'
          AND NOT EXISTS (SELECT 1 FROM dbo.THANH_TOAN t WHERE t.ma_hd = h.ma_hd AND t.trang_thai = 'THANH_CONG')
        ORDER BY h.ma_hd DESC""").fetchone()
    if not row:
        sys.exit("Không có hóa đơn CHO_THANH_TOAN chưa trả tiền nào để test.")
    ma_hd, so_tien = row
    barrier = threading.Barrier(n + 1)
    res = {"ok": 0, "rej": 0}
    lock = threading.Lock()

    def worker():
        cn = connect(cs)
        cu = cn.cursor()
        try:
            barrier.wait()
            cu.execute("EXEC dbo.sp_ThanhToan @ma_hd=?, @hinh_thuc='TIEN_MAT', @so_tien=?", ma_hd, so_tien)
            while cu.nextset():
                pass
            with lock:
                res["ok"] += 1
        except pyodbc.Error:
            with lock:
                res["rej"] += 1
        finally:
            cn.close()

    ts = [threading.Thread(target=worker) for _ in range(n)]
    for t in ts:
        t.start()
    barrier.wait()
    for t in ts:
        t.join()
    cnt = cur.execute("SELECT COUNT(*) FROM dbo.THANH_TOAN WHERE ma_hd=? AND trang_thai='THANH_CONG'", ma_hd).fetchone()[0]
    print(f"Hóa đơn #{ma_hd}, {n} luồng: thành công={res['ok']} (đúng=1), từ chối={res['rej']}, dòng THANH_CONG={cnt}")
    c.close()


def main():
    a = parse_args()
    cs = conn_string(a)
    {"overbook": overbook, "checkin": checkin, "spa_checkin": spa_checkin, "payment": payment}[a.kich_ban](a, cs)


if __name__ == "__main__":
    main()
