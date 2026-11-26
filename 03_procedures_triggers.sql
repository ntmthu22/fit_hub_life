/* =====================================================================
   FitLife Hub - CSC12002 - Đồ án 2627.ADB.01 - Nhóm 2627.ADB.CLC14
   Giai đoạn 2 - Script 03: function, stored procedure, trigger
   Thứ tự chạy:  01_create_schema.sql -> 02_generate_data.py -> 03 (file này) -> 04_scenarios.sql
   (Chạy 03 SAU khi nạp dữ liệu để trigger không làm chậm quá trình nạp.)
   Chạy lại nhiều lần được (CREATE OR ALTER).

   Mã lỗi nghiệp vụ (THROW):
     500xx  cửa/hội viên/lịch PT        510xx  hóa đơn/thanh toán
     520xx  ràng buộc dữ liệu (trigger)  590xx  chặn xóa vật lý (RB40)
   ===================================================================== */
USE FitLifeHub;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================
   0. KIỂU BẢNG (table-valued parameter) cho lập hóa đơn
   ===================================================================== */
IF TYPE_ID(N'dbo.ds_goi') IS NULL
    CREATE TYPE dbo.ds_goi AS TABLE (ma_goi SMALLINT NOT NULL);
GO
IF TYPE_ID(N'dbo.ds_sp') IS NULL
    CREATE TYPE dbo.ds_sp AS TABLE (
        ma_sp    INT NOT NULL PRIMARY KEY,
        so_luong INT NOT NULL CHECK (so_luong > 0));
GO

/* =====================================================================
   1. HÀM
   ===================================================================== */

-- Chi nhánh của nhân viên tại một ngày (vấn đề 5): dòng có tu_ngay <= D < den_ngay
CREATE OR ALTER FUNCTION dbo.fn_ChiNhanhCuaNV (@ma_nv INT, @ngay DATE)
RETURNS SMALLINT
AS
BEGIN
    RETURN (SELECT TOP (1) ma_cn
            FROM dbo.LICH_SU_CONG_TAC
            WHERE ma_nv = @ma_nv AND tu_ngay <= @ngay AND (den_ngay IS NULL OR @ngay < den_ngay)
            ORDER BY tu_ngay DESC);
END;
GO

-- Hạng theo tổng chi tiêu 12 tháng (RB39): hạng cao nhất có ngưỡng <= chi tiêu
CREATE OR ALTER FUNCTION dbo.fn_HangTheoChiTieu (@tong DECIMAL(15,0))
RETURNS TINYINT
AS
BEGIN
    RETURN ISNULL((SELECT MAX(ma_hang) FROM dbo.HANG_THANH_VIEN WHERE nguong_chi_tieu <= @tong), 1);
END;
GO

-- Điểm thưởng của một hóa đơn (RB38): FLOOR(thanh_toan / 100.000)
CREATE OR ALTER FUNCTION dbo.fn_DiemThuong (@thanh_toan DECIMAL(15,0))
RETURNS INT
AS
BEGIN
    RETURN CAST(FLOOR(@thanh_toan / 100000.0) AS INT);
END;
GO

/* =====================================================================
   2. TRIGGER
   ===================================================================== */

-- HOI_VIEN: mỗi hội viên mới có đúng một tài khoản loyalty (quan hệ 1-1)
CREATE OR ALTER TRIGGER dbo.trg_HOI_VIEN_ai ON dbo.HOI_VIEN AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.TAI_KHOAN_LOYALTY (ma_hv)
    SELECT i.ma_hv FROM inserted i
    WHERE NOT EXISTS (SELECT 1 FROM dbo.TAI_KHOAN_LOYALTY t WHERE t.ma_hv = i.ma_hv);
END;
GO

-- RB24: ngưỡng hạng tăng dần theo ma_hang; hạng thấp nhất có ngưỡng 0
CREATE OR ALTER TRIGGER dbo.trg_HANG_RB24 ON dbo.HANG_THANH_VIEN AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.HANG_THANH_VIEN a JOIN dbo.HANG_THANH_VIEN b
                 ON b.ma_hang > a.ma_hang AND b.nguong_chi_tieu <= a.nguong_chi_tieu)
       OR EXISTS (SELECT 1 FROM dbo.HANG_THANH_VIEN
                  WHERE ma_hang = (SELECT MIN(ma_hang) FROM dbo.HANG_THANH_VIEN) AND nguong_chi_tieu <> 0)
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52024, N'RB24: ngưỡng chi tiêu phải tăng dần theo mã hạng và hạng thấp nhất có ngưỡng 0', 1;
    END
END;
GO

-- RB28: dịch vụ PT <=> so_buoi_pt khác rỗng
CREATE OR ALTER TRIGGER dbo.trg_GOI_DICH_VU_RB28 ON dbo.GOI_DICH_VU AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.DICH_VU v ON v.ma_dv = i.ma_dv
               WHERE (v.nhom_dv = 'PT' AND i.so_buoi_pt IS NULL)
                  OR (v.nhom_dv <> 'PT' AND i.so_buoi_pt IS NOT NULL))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52028, N'RB28: gói của dịch vụ PT phải có số buổi PT; gói dịch vụ khác thì không', 1;
    END
END;
GO

-- RB13/RB30/RB31/RB34: lịch sử công tác
CREATE OR ALTER TRIGGER dbo.trg_LSCT_RB30 ON dbo.LICH_SU_CONG_TAC AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @max DATE = CAST('9999-12-31' AS DATE);
    -- RB30: các giai đoạn của một nhân viên không chồng lấn
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.LICH_SU_CONG_TAC l
                 ON l.ma_nv = i.ma_nv AND l.ma_ls <> i.ma_ls
                AND i.tu_ngay < ISNULL(l.den_ngay, @max) AND l.tu_ngay < ISNULL(i.den_ngay, @max))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52030, N'RB30: giai đoạn công tác chồng lấn với giai đoạn khác của cùng nhân viên', 1;
    END
    -- RB31 (phần chặn): một chi nhánh không có hai QUAN_LY chồng thời gian
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.LICH_SU_CONG_TAC l
                 ON l.ma_cn = i.ma_cn AND l.chuc_vu = 'QUAN_LY' AND l.ma_ls <> i.ma_ls
                AND i.tu_ngay < ISNULL(l.den_ngay, @max) AND l.tu_ngay < ISNULL(i.den_ngay, @max)
               WHERE i.chuc_vu = 'QUAN_LY')
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52031, N'RB31: chi nhánh đã có quản lý trong khoảng thời gian này', 1;
    END
    -- RB34: các lịch PT còn hiệu lực của HLV phải còn khớp chi nhánh/giai đoạn PT
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.LICH_HEN_PT p ON p.ma_hlv = i.ma_nv AND p.trang_thai <> 'DA_HUY'
               WHERE NOT EXISTS (SELECT 1 FROM dbo.LICH_SU_CONG_TAC l
                                 WHERE l.ma_nv = p.ma_hlv AND l.chuc_vu = 'PT' AND l.ma_cn = p.ma_cn
                                   AND l.tu_ngay <= p.ngay_tap AND (l.den_ngay IS NULL OR p.ngay_tap < l.den_ngay)))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52034, N'RB34: thay đổi này làm lịch PT đã đặt của HLV không còn đúng chi nhánh. Hãy hủy/chuyển lịch trước', 1;
    END
END;
GO

-- RB32: HLV phải là nhân viên có giai đoạn công tác chức vụ PT
CREATE OR ALTER TRIGGER dbo.trg_HLV_RB32 ON dbo.HUAN_LUYEN_VIEN AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM inserted i
               WHERE NOT EXISTS (SELECT 1 FROM dbo.LICH_SU_CONG_TAC l WHERE l.ma_nv = i.ma_nv AND l.chuc_vu = 'PT'))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52032, N'RB32: huấn luyện viên phải có giai đoạn công tác với chức vụ PT', 1;
    END
END;
GO

-- RB33 + RB41: người lập hóa đơn là lễ tân/NV bán hàng đang công tác tại chi nhánh vào ngày lập
CREATE OR ALTER TRIGGER dbo.trg_HOA_DON_RB33 ON dbo.HOA_DON AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(ma_nv_lap) OR UPDATE(ma_cn) OR UPDATE(ngay_lap)
       IF EXISTS (SELECT 1 FROM inserted i
                  WHERE NOT EXISTS (SELECT 1 FROM dbo.LICH_SU_CONG_TAC l
                                    WHERE l.ma_nv = i.ma_nv_lap AND l.ma_cn = i.ma_cn
                                      AND l.chuc_vu IN ('LE_TAN','NV_BAN_HANG')
                                      AND l.tu_ngay <= CAST(i.ngay_lap AS DATE)
                                      AND (l.den_ngay IS NULL OR CAST(i.ngay_lap AS DATE) < l.den_ngay)))
       BEGIN
           IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
           THROW 52033, N'RB33: người lập hóa đơn phải là lễ tân/NV bán hàng đang công tác tại chi nhánh', 1;
       END
    IF UPDATE(ma_hv)
       IF EXISTS (SELECT 1 FROM inserted i
                  WHERE i.ma_hv IS NULL AND EXISTS (SELECT 1 FROM dbo.GOI_DA_MUA g WHERE g.ma_hd = i.ma_hd))
       BEGIN
           IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
           THROW 52041, N'RB41: hóa đơn có gói dịch vụ bắt buộc có hội viên', 1;
       END
END;
GO

-- RB41: dòng gói chỉ được thêm vào hóa đơn có hội viên
CREATE OR ALTER TRIGGER dbo.trg_GOI_DA_MUA_RB41 ON dbo.GOI_DA_MUA AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(ma_hd)
       IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.HOA_DON h ON h.ma_hd = i.ma_hd WHERE h.ma_hv IS NULL)
       BEGIN
           IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
           THROW 52041, N'RB41: hóa đơn khách lẻ (không có hội viên) không được chứa gói dịch vụ', 1;
       END
END;
GO

/* Vấn đề 1: giữ bảng QUYEN_VAO_CONG đồng bộ khi GOI_DA_MUA thay đổi.
   1 dòng / (hội viên, dịch vụ) = gói HIEU_LUC có hạn xa nhất (vé Spa lẻ: còn lượt). */
CREATE OR ALTER TRIGGER dbo.trg_GOI_DA_MUA_QVC ON dbo.GOI_DA_MUA AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    IF NOT (UPDATE(trang_thai) OR UPDATE(ngay_het_han) OR UPDATE(so_buoi_con_lai) OR UPDATE(ma_goi) OR UPDATE(ma_hd))
       AND EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted) RETURN;

    DECLARE @k TABLE (ma_hv INT NOT NULL, ma_dv SMALLINT NOT NULL, PRIMARY KEY (ma_hv, ma_dv));
    INSERT INTO @k (ma_hv, ma_dv)
    SELECT DISTINCT h.ma_hv, d.ma_dv
    FROM (SELECT ma_hd, ma_goi FROM inserted UNION ALL SELECT ma_hd, ma_goi FROM deleted) x
    JOIN dbo.HOA_DON h ON h.ma_hd = x.ma_hd
    JOIN dbo.GOI_DICH_VU d ON d.ma_goi = x.ma_goi
    JOIN dbo.DICH_VU v ON v.ma_dv = d.ma_dv
    WHERE h.ma_hv IS NOT NULL AND v.nhom_dv IN ('PHONG_TAP','SPA_SAUNA');
    IF NOT EXISTS (SELECT 1 FROM @k) RETURN;

    DELETE q FROM dbo.QUYEN_VAO_CONG q JOIN @k k ON k.ma_hv = q.ma_hv AND k.ma_dv = q.ma_dv;

    INSERT INTO dbo.QUYEN_VAO_CONG (ma_hv, ma_dv, ngay_het_han, ma_goi_mua, so_luot_con_lai, cap_nhat_luc)
    SELECT z.ma_hv, z.ma_dv, z.ngay_het_han, z.ma_goi_mua, z.so_luot, SYSDATETIME()
    FROM (SELECT k.ma_hv, k.ma_dv, g.ngay_het_han, g.ma_goi_mua,
                 CASE WHEN d.thoi_han_thang IS NULL THEN g.so_buoi_con_lai END AS so_luot,
                 ROW_NUMBER() OVER (PARTITION BY k.ma_hv, k.ma_dv
                                    ORDER BY g.ngay_het_han DESC, g.ma_goi_mua DESC) AS rn
          FROM @k k
          JOIN dbo.HOA_DON h ON h.ma_hv = k.ma_hv
          JOIN dbo.GOI_DA_MUA g ON g.ma_hd = h.ma_hd
          JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi AND d.ma_dv = k.ma_dv
          WHERE g.trang_thai = 'HIEU_LUC' AND (d.thoi_han_thang IS NOT NULL OR g.so_buoi_con_lai > 0)) z
    WHERE z.rn = 1;
END;
GO

-- RB34: lịch PT - gói đúng hội viên, đúng loại PT, trong hạn; HLV thuộc chi nhánh vào ngày tập
CREATE OR ALTER TRIGGER dbo.trg_LICH_HEN_PT_RB34 ON dbo.LICH_HEN_PT AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE(ma_hv) OR UPDATE(ma_hlv) OR UPDATE(ma_cn) OR UPDATE(ma_goi_mua) OR UPDATE(ngay_tap)) RETURN;
    IF EXISTS (SELECT 1 FROM inserted i
               JOIN dbo.GOI_DA_MUA g ON g.ma_goi_mua = i.ma_goi_mua
               JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd
               JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
               JOIN dbo.DICH_VU v ON v.ma_dv = d.ma_dv
               WHERE h.ma_hv IS NULL OR h.ma_hv <> i.ma_hv OR v.nhom_dv <> 'PT'
                  OR i.ngay_tap < g.ngay_bat_dau OR i.ngay_tap > g.ngay_het_han)
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52035, N'RB34: gói phải thuộc đúng hội viên, là gói PT và còn hạn tại ngày tập', 1;
    END
    IF EXISTS (SELECT 1 FROM inserted i
               WHERE NOT EXISTS (SELECT 1 FROM dbo.LICH_SU_CONG_TAC l
                                 WHERE l.ma_nv = i.ma_hlv AND l.chuc_vu = 'PT' AND l.ma_cn = i.ma_cn
                                   AND l.tu_ngay <= i.ngay_tap AND (l.den_ngay IS NULL OR i.ngay_tap < l.den_ngay)))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52036, N'RB34: HLV không thuộc chi nhánh đặt lịch vào ngày tập', 1;
    END
END;
GO

-- RB37: sổ điểm bất biến, diem_hien_co được cộng dồn theo từng giao dịch điểm
CREATE OR ALTER TRIGGER dbo.trg_GDD_ai ON dbo.GIAO_DICH_DIEM AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE t SET t.diem_hien_co = t.diem_hien_co + s.d
    FROM dbo.TAI_KHOAN_LOYALTY t
    JOIN (SELECT ma_hv, SUM(so_diem) AS d FROM inserted GROUP BY ma_hv) s ON s.ma_hv = t.ma_hv;
END;
GO
CREATE OR ALTER TRIGGER dbo.trg_GDD_au ON dbo.GIAO_DICH_DIEM AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(so_diem) OR UPDATE(ma_hv)
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 52037, N'RB37: sổ giao dịch điểm là bất biến; hãy thêm giao dịch điều chỉnh', 1;
    END
END;
GO

-- RB40: không xóa vật lý hóa đơn, check-in, lịch PT, giao dịch điểm
CREATE OR ALTER TRIGGER dbo.trg_HOA_DON_nodel ON dbo.HOA_DON INSTEAD OF DELETE AS
BEGIN THROW 59040, N'RB40: không xóa vật lý hóa đơn; hãy chuyển trạng thái DA_HUY (sp_HuyHoaDon)', 1; END;
GO
CREATE OR ALTER TRIGGER dbo.trg_CHECK_IN_nodel ON dbo.CHECK_IN INSTEAD OF DELETE AS
BEGIN THROW 59041, N'RB40: không xóa vật lý lượt check-in', 1; END;
GO
CREATE OR ALTER TRIGGER dbo.trg_LICH_HEN_PT_nodel ON dbo.LICH_HEN_PT INSTEAD OF DELETE AS
BEGIN THROW 59042, N'RB40: không xóa vật lý lịch PT; hãy hủy lịch (sp_HuyLichPT)', 1; END;
GO
CREATE OR ALTER TRIGGER dbo.trg_GDD_nodel ON dbo.GIAO_DICH_DIEM INSTEAD OF DELETE AS
BEGIN THROW 59043, N'RB40: không xóa vật lý giao dịch điểm', 1; END;
GO

/* Vấn đề 4: toàn bộ hệ quả của việc đổi trạng thái hóa đơn gói trong MỘT trigger, theo tập hợp.
   Không đọc lại hóa đơn cũ nào: chỉ chạm các dòng loyalty/tổng hợp của chính hóa đơn này.
     CHO_THANH_TOAN -> DA_THANH_TOAN : kiểm RB26/RB41/RB42, kích hoạt gói (RB27), tích điểm (RB38),
                                       cộng dồn chi tiêu + xét hạng (RB39), cộng bảng tổng hợp
     DA_THANH_TOAN  -> DA_HUY        : hoàn điểm, trừ chi tiêu/tổng hợp, hủy gói, hoàn kho
     CHO_THANH_TOAN -> DA_HUY        : hủy gói, hoàn kho */
CREATE OR ALTER TRIGGER dbo.trg_HOA_DON_TrangThai ON dbo.HOA_DON AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(trang_thai) RETURN;

    IF EXISTS (SELECT 1 FROM inserted i JOIN deleted d ON d.ma_hd = i.ma_hd
               WHERE i.trang_thai <> d.trang_thai
                 AND NOT ((d.trang_thai = 'CHO_THANH_TOAN' AND i.trang_thai IN ('DA_THANH_TOAN','DA_HUY'))
                       OR (d.trang_thai = 'DA_THANH_TOAN'  AND i.trang_thai = 'DA_HUY')))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 51050, N'Chuyển trạng thái hóa đơn không hợp lệ (chỉ CHO_THANH_TOAN->DA_THANH_TOAN/DA_HUY, DA_THANH_TOAN->DA_HUY)', 1;
    END

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @x TABLE (
        ma_hd BIGINT PRIMARY KEY, hanh_dong CHAR(1) NOT NULL, sgn SMALLINT NOT NULL,
        ma_hv INT NULL, ma_cn SMALLINT NOT NULL, ngay DATE NOT NULL, thang DATE NOT NULL,
        thanh_toan DECIMAL(15,0) NOT NULL, giam DECIMAL(15,0) NOT NULL,
        goi_sum DECIMAL(15,0) NOT NULL, sp_sum DECIMAL(15,0) NOT NULL, pts INT NOT NULL);

    INSERT INTO @x
    SELECT i.ma_hd,
           CASE WHEN i.trang_thai = 'DA_THANH_TOAN' THEN 'P' WHEN d.trang_thai = 'DA_THANH_TOAN' THEN 'R' ELSE 'C' END,
           CASE WHEN i.trang_thai = 'DA_THANH_TOAN' THEN 1 ELSE -1 END,
           i.ma_hv, i.ma_cn, CAST(i.ngay_lap AS DATE), DATEFROMPARTS(YEAR(i.ngay_lap), MONTH(i.ngay_lap), 1),
           i.thanh_toan, i.giam_gia,
           ISNULL((SELECT SUM(g.don_gia) FROM dbo.GOI_DA_MUA g WHERE g.ma_hd = i.ma_hd), 0),
           ISNULL((SELECT SUM(c.so_luong * c.don_gia) FROM dbo.CT_HD_SAN_PHAM c WHERE c.ma_hd = i.ma_hd), 0),
           CAST(FLOOR(i.thanh_toan / 100000.0) AS INT)
    FROM inserted i JOIN deleted d ON d.ma_hd = i.ma_hd
    WHERE i.trang_thai <> d.trang_thai;
    IF NOT EXISTS (SELECT 1 FROM @x) RETURN;

    -- RB26: tổng thanh toán THANH_CONG (trừ HOAN_TIEN) = thanh_toan
    IF EXISTS (SELECT 1 FROM @x x WHERE x.hanh_dong = 'P'
               AND (SELECT ISNULL(SUM(CASE p.trang_thai WHEN 'THANH_CONG' THEN p.so_tien
                                                        WHEN 'HOAN_TIEN'  THEN -p.so_tien ELSE 0 END), 0)
                    FROM dbo.THANH_TOAN p WHERE p.ma_hd = x.ma_hd) <> x.thanh_toan)
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 51026, N'RB26: hóa đơn chỉ DA_THANH_TOAN khi tổng thanh toán thành công bằng số tiền phải trả', 1;
    END
    -- RB42: phải có ít nhất một dòng gói hoặc sản phẩm
    IF EXISTS (SELECT 1 FROM @x x WHERE x.hanh_dong = 'P' AND NOT EXISTS (SELECT 1 FROM dbo.GOI_DA_MUA g WHERE g.ma_hd = x.ma_hd)
                                                          AND NOT EXISTS (SELECT 1 FROM dbo.CT_HD_SAN_PHAM c WHERE c.ma_hd = x.ma_hd))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 51042, N'RB42: hóa đơn phải có ít nhất một dòng gói hoặc sản phẩm', 1;
    END
    -- RB41: hóa đơn có gói bắt buộc có hội viên (kể cả gói giá 0đ)
    IF EXISTS (SELECT 1 FROM @x x WHERE x.ma_hv IS NULL
                                    AND EXISTS (SELECT 1 FROM dbo.GOI_DA_MUA g WHERE g.ma_hd = x.ma_hd))
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 51041, N'RB41: hóa đơn có gói dịch vụ bắt buộc có hội viên', 1;
    END

    -- RB27: kích hoạt gói theo ngày thanh toán
    UPDATE g SET g.trang_thai = 'HIEU_LUC', g.ngay_bat_dau = @today,
                 g.ngay_het_han = CASE WHEN d.thoi_han_thang IS NULL THEN DATEADD(DAY, 30, @today)
                                       ELSE DATEADD(MONTH, d.thoi_han_thang, @today) END
    FROM dbo.GOI_DA_MUA g JOIN @x x ON x.ma_hd = g.ma_hd AND x.hanh_dong = 'P'
    JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
    WHERE g.trang_thai = 'CHO_KICH_HOAT';

    -- hủy: chặn nếu gói PT đã có buổi hoàn thành; tự hủy các lịch DA_DAT; hủy gói + hoàn kho (RB29)
    IF EXISTS (SELECT 1
               FROM @x x
               JOIN dbo.GOI_DA_MUA g ON g.ma_hd = x.ma_hd
               JOIN dbo.LICH_HEN_PT p ON p.ma_goi_mua = g.ma_goi_mua
               WHERE x.hanh_dong IN ('R','C') AND p.trang_thai = 'DA_HOAN_THANH')
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 51043, N'Không thể hủy hóa đơn có gói PT đã có buổi tập hoàn thành', 1;
    END

    UPDATE p SET p.trang_thai = 'DA_HUY', p.ly_do_huy = N'Hủy tự động do hủy hóa đơn',
                 p.diem_danh_gia = NULL, p.nhan_xet = NULL
    FROM dbo.LICH_HEN_PT p
    JOIN dbo.GOI_DA_MUA g ON g.ma_goi_mua = p.ma_goi_mua
    JOIN @x x ON x.ma_hd = g.ma_hd AND x.hanh_dong IN ('R','C')
    WHERE p.trang_thai = 'DA_DAT';

    UPDATE g SET g.trang_thai = 'DA_HUY'
    FROM dbo.GOI_DA_MUA g JOIN @x x ON x.ma_hd = g.ma_hd AND x.hanh_dong IN ('R','C')
    WHERE g.trang_thai <> 'DA_HUY';

    UPDATE t SET t.so_luong_ton = t.so_luong_ton + s.q, t.ngay_cap_nhat = SYSDATETIME()
    FROM dbo.TON_KHO t
    JOIN (SELECT x.ma_cn, c.ma_sp, SUM(c.so_luong) AS q
          FROM @x x JOIN dbo.CT_HD_SAN_PHAM c ON c.ma_hd = x.ma_hd
          WHERE x.hanh_dong IN ('R','C') GROUP BY x.ma_cn, c.ma_sp) s
      ON s.ma_cn = t.ma_cn AND s.ma_sp = t.ma_sp;

    -- RB38: tích điểm / hoàn điểm (diem_hien_co do trg_GDD_ai cộng)
    INSERT INTO dbo.GIAO_DICH_DIEM (ma_hv, ma_hd, loai_gd, so_diem, ngay_gd, ghi_chu)
    SELECT x.ma_hv, x.ma_hd, 'TICH', x.pts, SYSDATETIME(), NULL
    FROM @x x WHERE x.hanh_dong = 'P' AND x.ma_hv IS NOT NULL AND x.pts > 0;

    IF EXISTS (SELECT 1
               FROM (SELECT g.ma_hv, SUM(g.so_diem) AS hoan
                     FROM @x x JOIN dbo.GIAO_DICH_DIEM g ON g.ma_hd = x.ma_hd AND g.loai_gd = 'TICH'
                     WHERE x.hanh_dong = 'R' GROUP BY g.ma_hv) r
               JOIN dbo.TAI_KHOAN_LOYALTY t ON t.ma_hv = r.ma_hv
               WHERE t.diem_hien_co < r.hoan)
    BEGIN
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW 51044, N'Không thể hủy hóa đơn vì hội viên đã sử dụng điểm thưởng tích từ hóa đơn này', 1;
    END

    INSERT INTO dbo.GIAO_DICH_DIEM (ma_hv, ma_hd, loai_gd, so_diem, ngay_gd, ghi_chu)
    SELECT g.ma_hv, x.ma_hd, 'HOAN_TICH', -g.so_diem, SYSDATETIME(), N'Hoàn điểm do hủy hóa đơn'
    FROM @x x JOIN dbo.GIAO_DICH_DIEM g ON g.ma_hd = x.ma_hd AND g.loai_gd = 'TICH'
    WHERE x.hanh_dong = 'R';

    -- vấn đề 4: cộng dồn chi tiêu 12 tháng + nâng hạng ngay (RB39); chặn âm khi hoàn tiền kỳ cũ
    UPDATE t SET t.tong_chi_tieu_12t = CASE WHEN t.tong_chi_tieu_12t + s.d < 0 THEN 0 ELSE t.tong_chi_tieu_12t + s.d END,
                 t.ngay_xet_hang = @today
    FROM dbo.TAI_KHOAN_LOYALTY t
    JOIN (SELECT ma_hv, SUM(sgn * thanh_toan) AS d FROM @x
          WHERE ma_hv IS NOT NULL AND hanh_dong IN ('P','R') GROUP BY ma_hv) s ON s.ma_hv = t.ma_hv;

    UPDATE t SET t.ma_hang = ISNULL((SELECT MAX(h.ma_hang) FROM dbo.HANG_THANH_VIEN h
                                     WHERE h.nguong_chi_tieu <= t.tong_chi_tieu_12t), 1)
    FROM dbo.TAI_KHOAN_LOYALTY t
    WHERE t.ma_hv IN (SELECT ma_hv FROM @x WHERE ma_hv IS NOT NULL AND hanh_dong IN ('P','R'));

    MERGE dbo.CHI_TIEU_THANG_HV WITH (HOLDLOCK) AS tg
    USING (SELECT ma_hv, thang, SUM(sgn * thanh_toan) AS s FROM @x
           WHERE ma_hv IS NOT NULL AND hanh_dong IN ('P','R') GROUP BY ma_hv, thang) AS s
       ON tg.ma_hv = s.ma_hv AND tg.thang = s.thang
    WHEN MATCHED THEN UPDATE SET tg.tong_chi_tieu = CASE WHEN tg.tong_chi_tieu + s.s < 0 THEN 0 ELSE tg.tong_chi_tieu + s.s END
    WHEN NOT MATCHED AND s.s > 0 THEN INSERT (ma_hv, thang, tong_chi_tieu) VALUES (s.ma_hv, s.thang, s.s);

    -- vấn đề 3: bảng tổng hợp doanh thu cộng gia tăng (phân bổ giảm giá tối đa vào gói, phần dư trừ vào SP để không âm)
    MERGE dbo.TH_DOANH_THU_NGAY WITH (HOLDLOCK) AS tg
    USING (SELECT ma_cn, ngay, SUM(sgn) AS hd,
                  SUM(sgn * (goi_sum - CASE WHEN giam > goi_sum THEN goi_sum ELSE giam END)) AS g,
                  SUM(sgn * (sp_sum  - CASE WHEN giam > goi_sum THEN giam - goi_sum ELSE 0 END)) AS p
           FROM @x WHERE hanh_dong IN ('P','R') GROUP BY ma_cn, ngay) AS s
       ON tg.ma_cn = s.ma_cn AND tg.ngay = s.ngay
    WHEN MATCHED THEN UPDATE SET tg.so_hoa_don = tg.so_hoa_don + s.hd,
                                 tg.doanh_thu_goi = tg.doanh_thu_goi + s.g,
                                 tg.doanh_thu_san_pham = tg.doanh_thu_san_pham + s.p
    WHEN NOT MATCHED AND s.hd > 0 THEN INSERT (ma_cn, ngay, so_hoa_don, doanh_thu_goi, doanh_thu_san_pham)
                                       VALUES (s.ma_cn, s.ngay, s.hd, s.g, s.p);

    MERGE dbo.TH_DOANH_THU_GOI_THANG WITH (HOLDLOCK) AS tg
    USING (SELECT g.ma_goi, x.thang, SUM(x.sgn) AS sl, SUM(x.sgn * g.don_gia) AS dt
           FROM @x x JOIN dbo.GOI_DA_MUA g ON g.ma_hd = x.ma_hd
           WHERE x.hanh_dong IN ('P','R') GROUP BY g.ma_goi, x.thang) AS s
       ON tg.ma_goi = s.ma_goi AND tg.thang = s.thang
    WHEN MATCHED THEN UPDATE SET tg.so_luong_ban = tg.so_luong_ban + s.sl, tg.doanh_thu = tg.doanh_thu + s.dt
    WHEN NOT MATCHED AND s.sl > 0 THEN INSERT (ma_goi, thang, so_luong_ban, doanh_thu) VALUES (s.ma_goi, s.thang, s.sl, s.dt);
END;
GO

/* =====================================================================
   3. STORED PROCEDURE - TẦN SUẤT CAO
   ===================================================================== */

/* ---- Vấn đề 1: check-in giờ cao điểm (~10.000 lượt/giờ) -----------------
   Chỉ tra theo khóa: HOI_VIEN(ma_the) -> QUYEN_VAO_CONG(ma_hv) -> CN_DICH_VU, rồi chèn một dòng CHECK_IN. */
CREATE OR ALTER PROCEDURE dbo.sp_CheckIn
    @ma_the VARCHAR(30), @ma_cua SMALLINT, @tg DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @tg IS NULL SET @tg = SYSDATETIME();
    DECLARE @ngay DATE = CAST(@tg AS DATE), @ma_cn SMALLINT, @ma_hv INT, @tt_hv VARCHAR(10),
            @ma_goi_mua BIGINT, @luot INT, @ly_do NVARCHAR(100), @ma_checkin BIGINT;

    SELECT @ma_cn = k.ma_cn
    FROM dbo.CUA_KIEM_SOAT k
    JOIN dbo.CHI_NHANH cn ON cn.ma_cn = k.ma_cn AND cn.trang_thai = 'HOAT_DONG'
    WHERE k.ma_cua = @ma_cua AND k.trang_thai = 'HOAT_DONG';
    IF @ma_cn IS NULL THROW 50001, N'Cửa kiểm soát không tồn tại, đang bảo trì hoặc chi nhánh không hoạt động', 1;

    SELECT @ma_hv = ma_hv, @tt_hv = trang_thai FROM dbo.HOI_VIEN WHERE ma_the = @ma_the;
    IF @ma_hv IS NULL
    BEGIN
        SELECT CAST('TU_CHOI' AS VARCHAR(10)) AS ket_qua, N'Thẻ không hợp lệ' AS ly_do, CAST(NULL AS BIGINT) AS ma_checkin;
        RETURN;
    END

    IF @tt_hv = 'KHOA'
        SET @ly_do = N'Hội viên đang bị khóa';
    ELSE
    BEGIN
        -- ưu tiên gói định kỳ (luot IS NULL), sau đó gói có hạn xa nhất
        SELECT TOP (1) @ma_goi_mua = q.ma_goi_mua, @luot = q.so_luot_con_lai
        FROM dbo.QUYEN_VAO_CONG q
        JOIN dbo.CN_DICH_VU c ON c.ma_cn = @ma_cn AND c.ma_dv = q.ma_dv AND c.trang_thai = 'HOAT_DONG'
        WHERE q.ma_hv = @ma_hv AND q.ngay_het_han >= @ngay AND (q.so_luot_con_lai IS NULL OR q.so_luot_con_lai > 0)
        ORDER BY CASE WHEN q.so_luot_con_lai IS NULL THEN 0 ELSE 1 END, q.ngay_het_han DESC;
        IF @ma_goi_mua IS NULL SET @ly_do = N'Không có gói còn hạn dùng được tại chi nhánh này';
    END

    BEGIN TRAN;
    IF @ly_do IS NULL AND @luot IS NOT NULL      -- vé lẻ (Spa): trừ 1 lượt, hết lượt thì HET_HAN (RB35)
    BEGIN
        UPDATE dbo.GOI_DA_MUA
           SET so_buoi_con_lai = so_buoi_con_lai - 1,
               trang_thai = CASE WHEN so_buoi_con_lai - 1 = 0 THEN 'HET_HAN' ELSE trang_thai END
         WHERE ma_goi_mua = @ma_goi_mua AND so_buoi_con_lai > 0 AND trang_thai = 'HIEU_LUC';
        IF @@ROWCOUNT = 0 BEGIN SET @ly_do = N'Vé đã hết lượt'; SET @ma_goi_mua = NULL; END
    END

    IF @ly_do IS NULL
        -- RB36: mở lượt mới thì tự đóng lượt cũ chưa check-out (giới hạn 1 ngày để loại bớt phân vùng)
        UPDATE dbo.CHECK_IN SET tg_ra = @tg
         WHERE ma_hv = @ma_hv AND tg_ra IS NULL AND ket_qua = 'HOP_LE'
           AND tg_vao >= DATEADD(DAY, -1, @tg) AND tg_vao <= @tg;

    INSERT INTO dbo.CHECK_IN (ma_hv, ma_cua, ma_cn, ma_goi_mua, tg_vao, tg_ra, ket_qua)
    VALUES (@ma_hv, @ma_cua, @ma_cn, CASE WHEN @ly_do IS NULL THEN @ma_goi_mua END, @tg, NULL,
            CASE WHEN @ly_do IS NULL THEN 'HOP_LE' ELSE 'TU_CHOI' END);
    SET @ma_checkin = SCOPE_IDENTITY();
    COMMIT;

    SELECT CAST(CASE WHEN @ly_do IS NULL THEN 'HOP_LE' ELSE 'TU_CHOI' END AS VARCHAR(10)) AS ket_qua,
           @ly_do AS ly_do, @ma_checkin AS ma_checkin;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_CheckOut @ma_hv INT, @tg DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @tg IS NULL SET @tg = SYSDATETIME();
    UPDATE dbo.CHECK_IN SET tg_ra = @tg
     WHERE ma_hv = @ma_hv AND tg_ra IS NULL AND ket_qua = 'HOP_LE'
       AND tg_vao >= DATEADD(DAY, -1, @tg) AND tg_vao <= @tg;
    SELECT @@ROWCOUNT AS so_luot_dong;
END;
GO

/* ---- Vấn đề 2: đặt lịch PT chống overbooking ----------------------------
   Không "kiểm tra rồi ghi": INSERT thẳng, để UNIQUE có lọc (RB12) từ chối giao dịch đến sau.
   Trừ buổi bằng UPDATE có điều kiện + kiểm @@ROWCOUNT (RB34). */
CREATE OR ALTER PROCEDURE dbo.sp_DatLichPT
    @ma_hv INT, @ma_goi_mua BIGINT, @ma_hlv INT, @ngay_tap DATE, @ma_khung_gio TINYINT,
    @ma_lich BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ma_cn SMALLINT;
    IF @ngay_tap < CAST(SYSDATETIME() AS DATE) THROW 50010, N'Không thể đặt lịch cho ngày đã qua', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.HOI_VIEN WHERE ma_hv = @ma_hv AND trang_thai = 'HOAT_DONG')
        THROW 50011, N'Hội viên không tồn tại hoặc đang bị khóa', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.GOI_DA_MUA g
                   JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd
                   JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
                   JOIN dbo.DICH_VU v ON v.ma_dv = d.ma_dv
                   WHERE g.ma_goi_mua = @ma_goi_mua AND h.ma_hv = @ma_hv AND v.nhom_dv = 'PT'
                     AND g.trang_thai = 'HIEU_LUC' AND @ngay_tap BETWEEN g.ngay_bat_dau AND g.ngay_het_han)
        THROW 50012, N'Gói PT không thuộc hội viên, không còn hiệu lực hoặc đã hết hạn tại ngày tập', 1;
    SET @ma_cn = (SELECT TOP (1) l.ma_cn
                  FROM dbo.LICH_SU_CONG_TAC l
                  JOIN dbo.CHI_NHANH cn ON cn.ma_cn = l.ma_cn AND cn.trang_thai = 'HOAT_DONG'
                  WHERE l.ma_nv = @ma_hlv AND l.chuc_vu = 'PT' AND l.tu_ngay <= @ngay_tap
                    AND (l.den_ngay IS NULL OR @ngay_tap < l.den_ngay));
    IF @ma_cn IS NULL THROW 50013, N'Người này không phải HLV (PT) đang công tác tại chi nhánh hoạt động vào ngày tập', 1;

    BEGIN TRY
        BEGIN TRAN;
        INSERT INTO dbo.LICH_HEN_PT (ma_hv, ma_hlv, ma_cn, ma_goi_mua, ngay_tap, ma_khung_gio)
        VALUES (@ma_hv, @ma_hlv, @ma_cn, @ma_goi_mua, @ngay_tap, @ma_khung_gio);
        SET @ma_lich = SCOPE_IDENTITY();
        UPDATE dbo.GOI_DA_MUA SET so_buoi_con_lai = so_buoi_con_lai - 1
         WHERE ma_goi_mua = @ma_goi_mua AND so_buoi_con_lai > 0 AND trang_thai = 'HIEU_LUC';
        IF @@ROWCOUNT = 0 THROW 50014, N'Gói PT đã hết buổi', 1;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            IF ERROR_MESSAGE() LIKE N'%UX_LHPT_hv_khung%'
                THROW 50015, N'Hội viên đã có lịch PT khác trong khung giờ này', 1;
            THROW 50016, N'Khung giờ này của HLV đã có người đặt', 1;
        END;
        THROW;
    END CATCH
    SELECT @ma_lich AS ma_lich, @ma_cn AS ma_cn;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_HuyLichPT @ma_lich BIGINT, @ly_do NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF @ly_do IS NULL OR LTRIM(RTRIM(@ly_do)) = N'' THROW 50020, N'Phải ghi lý do hủy lịch (RB21)', 1;
    DECLARE @gm BIGINT;
    BEGIN TRAN;
    UPDATE dbo.LICH_HEN_PT SET trang_thai = 'DA_HUY', ly_do_huy = @ly_do, diem_danh_gia = NULL, nhan_xet = NULL
     WHERE ma_lich = @ma_lich AND trang_thai = 'DA_DAT';
    IF @@ROWCOUNT = 0 THROW 50021, N'Chỉ hủy được lịch đang ở trạng thái DA_DAT', 1;
    SELECT @gm = ma_goi_mua FROM dbo.LICH_HEN_PT WHERE ma_lich = @ma_lich;
    UPDATE g SET g.so_buoi_con_lai = g.so_buoi_con_lai + 1       -- hoàn 1 buổi trong cùng giao dịch
      FROM dbo.GOI_DA_MUA g JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
     WHERE g.ma_goi_mua = @gm AND g.so_buoi_con_lai < d.so_buoi_pt;
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_HoanThanhLichPT
    @ma_lich BIGINT, @diem_danh_gia TINYINT = NULL, @nhan_xet NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.LICH_HEN_PT SET trang_thai = 'DA_HOAN_THANH', diem_danh_gia = @diem_danh_gia, nhan_xet = @nhan_xet
     WHERE ma_lich = @ma_lich AND trang_thai = 'DA_DAT' AND ngay_tap <= CAST(SYSDATETIME() AS DATE);
    IF @@ROWCOUNT = 0 THROW 50022, N'Chỉ hoàn thành được lịch DA_DAT có ngày tập đã đến', 1;
END;
GO

/* ---- Lập hóa đơn (RB25, RB29, RB41, RB42) ------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_LapHoaDon
    @ma_hv INT = NULL, @ma_nv_lap INT, @ma_cn SMALLINT,
    @goi dbo.ds_goi READONLY, @sp dbo.ds_sp READONLY,
    @giam_gia DECIMAL(15,0) = 0, @ma_hd BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ng INT = (SELECT COUNT(*) FROM @goi), @ns INT = (SELECT COUNT(*) FROM @sp),
            @goi_sum DECIMAL(15,0), @sp_sum DECIMAL(15,0), @today DATE = CAST(SYSDATETIME() AS DATE);

    IF @ng + @ns = 0 THROW 51001, N'RB42: hóa đơn phải có ít nhất một gói hoặc sản phẩm', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.CHI_NHANH WHERE ma_cn = @ma_cn AND trang_thai = 'HOAT_DONG')
        THROW 51009, N'Chi nhánh không tồn tại hoặc không hoạt động', 1;
    IF @ma_hv IS NULL AND @ng > 0 THROW 51002, N'RB41: hóa đơn có gói bắt buộc có hội viên', 1;
    IF @ma_hv IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.HOI_VIEN WHERE ma_hv = @ma_hv AND trang_thai = 'HOAT_DONG')
        THROW 51003, N'Hội viên không tồn tại hoặc đang bị khóa', 1;
    IF (SELECT COUNT(*) FROM @goi a JOIN dbo.GOI_DICH_VU d ON d.ma_goi = a.ma_goi AND d.trang_thai_ban = 'DANG_BAN') <> @ng
        THROW 51004, N'Có gói không tồn tại hoặc đã ngừng bán', 1;
    IF EXISTS (SELECT 1 FROM @goi a JOIN dbo.GOI_DICH_VU d ON d.ma_goi = a.ma_goi
               WHERE NOT EXISTS (SELECT 1 FROM dbo.CN_DICH_VU c WHERE c.ma_cn = @ma_cn AND c.ma_dv = d.ma_dv AND c.trang_thai = 'HOAT_DONG'))
        THROW 51005, N'Chi nhánh không cung cấp dịch vụ của gói đã chọn', 1;
    IF (SELECT COUNT(*) FROM @sp s JOIN dbo.SAN_PHAM p ON p.ma_sp = s.ma_sp AND p.trang_thai = 'DANG_BAN') <> @ns
        THROW 51006, N'Có sản phẩm không tồn tại hoặc đã ngừng bán', 1;

    SELECT @goi_sum = ISNULL(SUM(d.gia_tien), 0) FROM @goi a JOIN dbo.GOI_DICH_VU d ON d.ma_goi = a.ma_goi;
    SELECT @sp_sum  = ISNULL(SUM(s.so_luong * p.gia_ban), 0) FROM @sp s JOIN dbo.SAN_PHAM p ON p.ma_sp = s.ma_sp;
    IF @giam_gia < 0 OR @giam_gia > @goi_sum + @sp_sum THROW 51007, N'RB19: giảm giá không hợp lệ', 1;

    BEGIN TRAN;
    INSERT INTO dbo.HOA_DON (ma_hv, ma_nv_lap, ma_cn, tong_tien, giam_gia, thanh_toan, trang_thai)
    VALUES (@ma_hv, @ma_nv_lap, @ma_cn, @goi_sum + @sp_sum, @giam_gia, @goi_sum + @sp_sum - @giam_gia, 'CHO_THANH_TOAN');
    SET @ma_hd = SCOPE_IDENTITY();

    INSERT INTO dbo.GOI_DA_MUA (ma_hd, ma_goi, don_gia, ngay_bat_dau, ngay_het_han, so_buoi_con_lai, trang_thai)
    SELECT @ma_hd, d.ma_goi, d.gia_tien, @today,
           CASE WHEN d.thoi_han_thang IS NULL THEN DATEADD(DAY, 30, @today) ELSE DATEADD(MONTH, d.thoi_han_thang, @today) END,
           COALESCE(d.so_buoi_pt, CASE WHEN d.thoi_han_thang IS NULL THEN 1 END), 'CHO_KICH_HOAT'
    FROM @goi a JOIN dbo.GOI_DICH_VU d ON d.ma_goi = a.ma_goi;

    INSERT INTO dbo.CT_HD_SAN_PHAM (ma_hd, ma_sp, so_luong, don_gia)
    SELECT @ma_hd, s.ma_sp, s.so_luong, p.gia_ban FROM @sp s JOIN dbo.SAN_PHAM p ON p.ma_sp = s.ma_sp;

    -- RB29: trừ tồn kho của chi nhánh lập hóa đơn, không để âm
    UPDATE t SET t.so_luong_ton = t.so_luong_ton - s.so_luong, t.ngay_cap_nhat = SYSDATETIME()
      FROM dbo.TON_KHO t JOIN @sp s ON s.ma_sp = t.ma_sp
     WHERE t.ma_cn = @ma_cn AND t.so_luong_ton >= s.so_luong;
    IF @@ROWCOUNT <> @ns THROW 51008, N'RB29: không đủ tồn kho tại chi nhánh', 1;
    COMMIT;
    SELECT @ma_hd AS ma_hd, @goi_sum + @sp_sum - @giam_gia AS can_thanh_toan;
END;
GO

/* ---- Thanh toán: chỉ chạm hóa đơn + 1 dòng loyalty qua trigger (vấn đề 4) ---- */
CREATE OR ALTER PROCEDURE dbo.sp_ThanhToan
    @ma_hd BIGINT, @hinh_thuc VARCHAR(10), @so_tien DECIMAL(15,0),
    @ma_giao_dich_cong VARCHAR(50) = NULL, @thanh_cong BIT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @phai_tra DECIMAL(15,0), @tt VARCHAR(15), @da_tra DECIMAL(15,0);
    BEGIN TRAN;
    SELECT @phai_tra = thanh_toan, @tt = trang_thai FROM dbo.HOA_DON WITH (UPDLOCK, HOLDLOCK) WHERE ma_hd = @ma_hd;
    IF @tt IS NULL THROW 51010, N'Không tìm thấy hóa đơn', 1;
    IF @tt <> 'CHO_THANH_TOAN' THROW 51011, N'Hóa đơn không ở trạng thái chờ thanh toán', 1;

    INSERT INTO dbo.THANH_TOAN (ma_hd, hinh_thuc, so_tien, ma_giao_dich_cong, trang_thai)
    VALUES (@ma_hd, @hinh_thuc, @so_tien, @ma_giao_dich_cong, CASE WHEN @thanh_cong = 1 THEN 'THANH_CONG' ELSE 'THAT_BAI' END);

    SELECT @da_tra = ISNULL(SUM(so_tien), 0) FROM dbo.THANH_TOAN WHERE ma_hd = @ma_hd AND trang_thai = 'THANH_CONG';
    IF @da_tra > @phai_tra THROW 51012, N'Số tiền thanh toán vượt quá số phải trả', 1;
    IF @da_tra = @phai_tra
        UPDATE dbo.HOA_DON SET trang_thai = 'DA_THANH_TOAN' WHERE ma_hd = @ma_hd;   -- trg_HOA_DON_TrangThai làm phần còn lại
    COMMIT;
    SELECT CASE WHEN @da_tra = @phai_tra THEN 'DA_THANH_TOAN' ELSE 'CHO_THANH_TOAN' END AS trang_thai_hoa_don,
           @phai_tra - @da_tra AS con_phai_tra;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_HuyHoaDon @ma_hd BIGINT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @tt VARCHAR(15);
    BEGIN TRAN;
    SELECT @tt = trang_thai FROM dbo.HOA_DON WITH (UPDLOCK, HOLDLOCK) WHERE ma_hd = @ma_hd;
    IF @tt IS NULL OR @tt = 'DA_HUY' THROW 51020, N'Hóa đơn không tồn tại hoặc đã hủy', 1;
    IF EXISTS (SELECT 1 FROM dbo.THANH_TOAN WHERE ma_hd = @ma_hd AND trang_thai = 'THANH_CONG')
        INSERT INTO dbo.THANH_TOAN (ma_hd, hinh_thuc, so_tien, ma_giao_dich_cong, trang_thai)
        SELECT ma_hd, hinh_thuc, so_tien,
               CASE WHEN ma_giao_dich_cong IS NULL THEN NULL ELSE LEFT('RF' + ma_giao_dich_cong, 50) END,
               'HOAN_TIEN'
        FROM dbo.THANH_TOAN WHERE ma_hd = @ma_hd AND trang_thai = 'THANH_CONG';
    UPDATE dbo.HOA_DON SET trang_thai = 'DA_HUY' WHERE ma_hd = @ma_hd;
    COMMIT;
END;
GO

/* =====================================================================
   4. STORED PROCEDURE - TÌM KIẾM, THÊM/SỬA/KHÓA (ứng dụng)
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.sp_TraCuuHoiVien @tu_khoa NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (50) hv.ma_hv, hv.ma_the, hv.ho_ten, hv.sdt, hv.email, hv.cccd, hv.gioi_tinh, hv.ngay_sinh,
           hv.ngay_dang_ky, hv.trang_thai, h.ten_hang, t.diem_hien_co
    FROM dbo.HOI_VIEN hv
    LEFT JOIN dbo.TAI_KHOAN_LOYALTY t ON t.ma_hv = hv.ma_hv
    LEFT JOIN dbo.HANG_THANH_VIEN h ON h.ma_hang = t.ma_hang
    WHERE hv.ma_the = @tu_khoa OR hv.sdt = @tu_khoa OR hv.cccd = @tu_khoa OR hv.ho_ten LIKE @tu_khoa + N'%'
    ORDER BY hv.ma_hv;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_ThemHoiVien
    @ma_the VARCHAR(30), @ho_ten NVARCHAR(100), @sdt VARCHAR(15), @email VARCHAR(100) = NULL,
    @cccd CHAR(12), @gioi_tinh CHAR(1), @ngay_sinh DATE, @ma_hv INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.HOI_VIEN (ma_the, ho_ten, sdt, email, cccd, gioi_tinh, ngay_sinh)
    VALUES (@ma_the, @ho_ten, @sdt, @email, @cccd, @gioi_tinh, @ngay_sinh);
    SET @ma_hv = SCOPE_IDENTITY();
    SELECT @ma_hv AS ma_hv;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_CapNhatHoiVien
    @ma_hv INT, @ho_ten NVARCHAR(100), @sdt VARCHAR(15), @email VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.HOI_VIEN SET ho_ten = @ho_ten, sdt = @sdt, email = @email WHERE ma_hv = @ma_hv;
    IF @@ROWCOUNT = 0 THROW 50030, N'Không tìm thấy hội viên', 1;
END;
GO

-- "Xóa" hội viên = khóa thẻ (không xóa vật lý, vì còn hóa đơn/check-in/điểm)
CREATE OR ALTER PROCEDURE dbo.sp_KhoaHoiVien @ma_hv INT, @khoa BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.HOI_VIEN SET trang_thai = CASE WHEN @khoa = 1 THEN 'KHOA' ELSE 'HOAT_DONG' END WHERE ma_hv = @ma_hv;
    IF @@ROWCOUNT = 0 THROW 50030, N'Không tìm thấy hội viên', 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_LichSuTap @ma_hv INT, @tu DATE = NULL, @den DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @den = ISNULL(@den, CAST(SYSDATETIME() AS DATE));
    SET @tu  = ISNULL(@tu, DATEADD(MONTH, -3, @den));
    DECLARE @t0 DATETIME2(0) = @tu, @t1 DATETIME2(0) = DATEADD(DAY, 1, @den);
    SELECT c.tg_vao, c.tg_ra, c.ket_qua, cn.ten_cn, k.vi_tri
    FROM dbo.CHECK_IN c JOIN dbo.CHI_NHANH cn ON cn.ma_cn = c.ma_cn JOIN dbo.CUA_KIEM_SOAT k ON k.ma_cua = c.ma_cua
    WHERE c.ma_hv = @ma_hv AND c.tg_vao >= @t0 AND c.tg_vao < @t1
    ORDER BY c.tg_vao DESC;
    SELECT p.ma_lich, p.ngay_tap, kg.gio_bat_dau, nv.ho_ten AS hlv, cn.ten_cn, p.trang_thai, p.diem_danh_gia, p.ly_do_huy
    FROM dbo.LICH_HEN_PT p JOIN dbo.KHUNG_GIO kg ON kg.ma_khung_gio = p.ma_khung_gio
    JOIN dbo.NHAN_VIEN nv ON nv.ma_nv = p.ma_hlv JOIN dbo.CHI_NHANH cn ON cn.ma_cn = p.ma_cn
    WHERE p.ma_hv = @ma_hv AND p.ngay_tap BETWEEN @tu AND @den
    ORDER BY p.ngay_tap DESC, kg.gio_bat_dau;
END;
GO

/* =====================================================================
   5. STORED PROCEDURE - BÁO CÁO, THỐNG KÊ
   ===================================================================== */

-- Doanh thu theo ngày/tháng/quý/năm, đọc từ bảng tổng hợp (vấn đề 3)
CREATE OR ALTER PROCEDURE dbo.sp_BaoCaoDoanhThu
    @cap VARCHAR(5), @tu DATE, @den DATE, @ma_cn SMALLINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @cap NOT IN ('NGAY','THANG','QUY','NAM') THROW 50040, N'@cap phải là NGAY, THANG, QUY hoặc NAM', 1;
    SELECT v.ky, SUM(t.so_hoa_don) AS so_hoa_don, SUM(t.doanh_thu_goi) AS doanh_thu_goi,
           SUM(t.doanh_thu_san_pham) AS doanh_thu_san_pham, SUM(t.doanh_thu_goi + t.doanh_thu_san_pham) AS tong_doanh_thu
    FROM dbo.TH_DOANH_THU_NGAY t
    CROSS APPLY (VALUES (CASE @cap WHEN 'NGAY'  THEN t.ngay
                                   WHEN 'THANG' THEN DATEFROMPARTS(YEAR(t.ngay), MONTH(t.ngay), 1)
                                   WHEN 'QUY'   THEN DATEFROMPARTS(YEAR(t.ngay), (DATEPART(QUARTER, t.ngay) - 1) * 3 + 1, 1)
                                   ELSE DATEFROMPARTS(YEAR(t.ngay), 1, 1) END)) v(ky)
    WHERE t.ngay BETWEEN @tu AND @den AND (@ma_cn IS NULL OR t.ma_cn = @ma_cn)
    GROUP BY v.ky ORDER BY v.ky;
END;
GO

-- Tỷ lệ lấp đầy theo khung giờ (vấn đề 3): người có mặt / sức chứa phòng tập
CREATE OR ALTER PROCEDURE dbo.sp_BaoCaoLapDay @ma_cn SMALLINT, @tu DATE, @den DATE
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @suc_chua INT = (SELECT SUM(c.suc_chua) FROM dbo.CN_DICH_VU c JOIN dbo.DICH_VU v ON v.ma_dv = c.ma_dv
                             WHERE c.ma_cn = @ma_cn AND v.nhom_dv = 'PHONG_TAP' AND c.trang_thai = 'HOAT_DONG');
    SELECT t.gio, SUM(t.so_luot_vao) AS tong_luot_vao,
           CAST(AVG(t.so_nguoi_co_mat * 1.0) AS DECIMAL(9,2)) AS tb_nguoi_co_mat,
           CAST(AVG(t.so_nguoi_co_mat * 100.0) / NULLIF(@suc_chua, 0) AS DECIMAL(6,2)) AS ty_le_lap_day_pct
    FROM dbo.TH_LAP_DAY_GIO t
    WHERE t.ma_cn = @ma_cn AND t.ngay BETWEEN @tu AND @den
    GROUP BY t.gio ORDER BY t.gio;
END;
GO

-- Nạp TH_LAP_DAY_GIO từ CHECK_IN cho một ngày (chạy mỗi giờ/đêm)
CREATE OR ALTER PROCEDURE dbo.sp_NapLapDayGio @ngay DATE
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @t0 DATETIME2(0) = @ngay, @t1 DATETIME2(0) = DATEADD(DAY, 1, @ngay);
    BEGIN TRAN;
    DELETE FROM dbo.TH_LAP_DAY_GIO WHERE ngay = @ngay;
    ;WITH h AS (SELECT TOP (24) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS gio FROM sys.all_objects)
    INSERT INTO dbo.TH_LAP_DAY_GIO (ma_cn, ngay, gio, so_luot_vao, so_nguoi_co_mat)
    SELECT c.ma_cn, @ngay, h.gio,
           SUM(CASE WHEN DATEPART(HOUR, c.tg_vao) = h.gio THEN 1 ELSE 0 END), COUNT(*)
    FROM dbo.CHECK_IN c
    JOIN h ON DATEPART(HOUR, c.tg_vao) <= h.gio
          AND CASE WHEN c.tg_ra IS NULL THEN DATEPART(HOUR, c.tg_vao)
                   WHEN CAST(c.tg_ra AS DATE) > @ngay THEN 23
                   ELSE DATEPART(HOUR, c.tg_ra) END >= h.gio
    WHERE c.tg_vao >= @t0 AND c.tg_vao < @t1 AND c.ket_qua = 'HOP_LE'
    GROUP BY c.ma_cn, h.gio;
    COMMIT;
END;
GO

-- Danh sách hội viên check-in trong ngày theo khung giờ
CREATE OR ALTER PROCEDURE dbo.sp_DSCheckInTheoGio @ma_cn SMALLINT, @ngay DATE, @gio_tu TINYINT = 0, @gio_den TINYINT = 23
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2(0) = DATEADD(HOUR, @gio_tu, CAST(@ngay AS DATETIME2(0))),
            @t1 DATETIME2(0) = DATEADD(HOUR, @gio_den + 1, CAST(@ngay AS DATETIME2(0)));
    SELECT c.tg_vao, c.tg_ra, hv.ma_hv, hv.ho_ten, hv.ma_the, c.ket_qua
    FROM dbo.CHECK_IN c JOIN dbo.HOI_VIEN hv ON hv.ma_hv = c.ma_hv
    WHERE c.ma_cn = @ma_cn AND c.tg_vao >= @t0 AND c.tg_vao < @t1
    ORDER BY c.tg_vao;
END;
GO

-- Gói/sản phẩm bán chạy nhất tại chi nhánh
CREATE OR ALTER PROCEDURE dbo.sp_TopGoiSanPham @ma_cn SMALLINT, @tu DATE, @den DATE, @top INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME2(0) = @tu, @t1 DATETIME2(0) = DATEADD(DAY, 1, @den);
    SELECT TOP (@top) d.ten_goi, COUNT(*) AS so_luong_ban, SUM(g.don_gia) AS doanh_thu
    FROM dbo.GOI_DA_MUA g JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
    WHERE h.ma_cn = @ma_cn AND h.trang_thai = 'DA_THANH_TOAN' AND h.ngay_lap >= @t0 AND h.ngay_lap < @t1
    GROUP BY d.ten_goi ORDER BY so_luong_ban DESC;
    SELECT TOP (@top) p.ten_sp, SUM(c.so_luong) AS so_luong_ban, SUM(c.so_luong * c.don_gia) AS doanh_thu
    FROM dbo.CT_HD_SAN_PHAM c JOIN dbo.HOA_DON h ON h.ma_hd = c.ma_hd JOIN dbo.SAN_PHAM p ON p.ma_sp = c.ma_sp
    WHERE h.ma_cn = @ma_cn AND h.trang_thai = 'DA_THANH_TOAN' AND h.ngay_lap >= @t0 AND h.ngay_lap < @t1
    GROUP BY p.ten_sp ORDER BY so_luong_ban DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_BaoCaoTonKho @ma_cn SMALLINT, @chi_canh_bao BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT l.ten_loai, p.ten_sp, t.so_luong_ton, t.muc_ton_toi_thieu,
           CASE WHEN t.so_luong_ton < t.muc_ton_toi_thieu THEN N'Cần nhập thêm' ELSE N'Đủ' END AS canh_bao
    FROM dbo.TON_KHO t JOIN dbo.SAN_PHAM p ON p.ma_sp = t.ma_sp JOIN dbo.LOAI_SAN_PHAM l ON l.ma_loai = p.ma_loai
    WHERE t.ma_cn = @ma_cn AND (@chi_canh_bao = 0 OR t.so_luong_ton < t.muc_ton_toi_thieu)
    ORDER BY l.ten_loai, p.ten_sp;
END;
GO

-- Hiệu suất HLV: số buổi dạy, điểm đánh giá
CREATE OR ALTER PROCEDURE dbo.sp_HieuSuatHLV @ma_cn SMALLINT = NULL, @tu DATE, @den DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.ma_hlv, nv.ho_ten, p.ma_cn,
           SUM(CASE WHEN p.trang_thai = 'DA_HOAN_THANH' THEN 1 ELSE 0 END) AS so_buoi_day,
           SUM(CASE WHEN p.trang_thai = 'DA_HUY' THEN 1 ELSE 0 END) AS so_buoi_huy,
           CAST(AVG(CAST(p.diem_danh_gia AS DECIMAL(4,2))) AS DECIMAL(4,2)) AS diem_danh_gia_tb
    FROM dbo.LICH_HEN_PT p JOIN dbo.NHAN_VIEN nv ON nv.ma_nv = p.ma_hlv
    WHERE p.ngay_tap BETWEEN @tu AND @den AND (@ma_cn IS NULL OR p.ma_cn = @ma_cn)
    GROUP BY p.ma_hlv, nv.ho_ten, p.ma_cn
    ORDER BY so_buoi_day DESC;
END;
GO

-- BC06: hội viên sắp hết hạn gói hoặc lâu chưa quay lại
CREATE OR ALTER PROCEDURE dbo.sp_HoiVienSapHetHan
    @ma_cn SMALLINT = NULL, @so_ngay_het_han INT = 14, @so_ngay_vang INT = 30
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE), @now DATETIME2(0) = SYSDATETIME(),
            @moc DATETIME2(0) = DATEADD(DAY, -@so_ngay_vang, SYSDATETIME());
    SELECT hv.ma_hv, hv.ho_ten, hv.sdt, v.ten_dv, q.ngay_het_han,
           CASE WHEN q.ngay_het_han <= DATEADD(DAY, @so_ngay_het_han, @today) THEN N'Sắp hết hạn' ELSE N'Lâu chưa quay lại' END AS ly_do
    FROM dbo.QUYEN_VAO_CONG q
    JOIN dbo.GOI_DA_MUA g ON g.ma_goi_mua = q.ma_goi_mua
    JOIN dbo.HOA_DON h ON h.ma_hd = g.ma_hd
    JOIN dbo.HOI_VIEN hv ON hv.ma_hv = q.ma_hv
    JOIN dbo.DICH_VU v ON v.ma_dv = q.ma_dv
    WHERE (@ma_cn IS NULL OR h.ma_cn = @ma_cn) AND hv.trang_thai = 'HOAT_DONG' AND q.ngay_het_han >= @today
      AND (q.ngay_het_han <= DATEADD(DAY, @so_ngay_het_han, @today)
           OR NOT EXISTS (SELECT 1 FROM dbo.CHECK_IN c
                          WHERE c.ma_hv = q.ma_hv AND c.ket_qua = 'HOP_LE' AND c.tg_vao >= @moc AND c.tg_vao <= @now))
    ORDER BY q.ngay_het_han;
END;
GO

-- Cấp công ty
CREATE OR ALTER PROCEDURE dbo.sp_DoanhThuToanHeThong @tu DATE, @den DATE
AS
BEGIN
    SET NOCOUNT ON;
    SELECT cn.ma_cn, cn.ten_cn, SUM(t.so_hoa_don) AS so_hoa_don, SUM(t.doanh_thu_goi + t.doanh_thu_san_pham) AS doanh_thu,
           RANK() OVER (ORDER BY SUM(t.doanh_thu_goi + t.doanh_thu_san_pham) DESC) AS xep_hang
    FROM dbo.TH_DOANH_THU_NGAY t JOIN dbo.CHI_NHANH cn ON cn.ma_cn = t.ma_cn
    WHERE t.ngay BETWEEN @tu AND @den
    GROUP BY cn.ma_cn, cn.ten_cn ORDER BY doanh_thu DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_GoiDoanhThuCaoNhat6Thang @top INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @tu DATE = DATEADD(MONTH, -5, DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1));
    SELECT TOP (@top) d.ten_goi, SUM(t.so_luong_ban) AS so_luong_ban, SUM(t.doanh_thu) AS doanh_thu
    FROM dbo.TH_DOANH_THU_GOI_THANG t JOIN dbo.GOI_DICH_VU d ON d.ma_goi = t.ma_goi
    WHERE t.thang >= @tu
    GROUP BY d.ten_goi ORDER BY doanh_thu DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_PhanBoHangHoiVien
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.ten_hang, COUNT(t.ma_hv) AS so_hoi_vien,
           CAST(COUNT(t.ma_hv) * 100.0 / NULLIF(SUM(COUNT(t.ma_hv)) OVER (), 0) AS DECIMAL(5,2)) AS ty_le_pct
    FROM dbo.HANG_THANH_VIEN h LEFT JOIN dbo.TAI_KHOAN_LOYALTY t ON t.ma_hang = h.ma_hang
    GROUP BY h.ma_hang, h.ten_hang ORDER BY h.ma_hang;
END;
GO

/* =====================================================================
   6. STORED PROCEDURE - NHÂN SỰ VÀ HOA HỒNG (vấn đề 5)
   ===================================================================== */

-- Điều chuyển: đóng giai đoạn cũ, mở giai đoạn mới cùng ngày (khoảng nửa mở, không kẽ hở/chồng lấn)
CREATE OR ALTER PROCEDURE dbo.sp_DieuChuyenNhanVien
    @ma_nv INT, @ma_cn_moi SMALLINT, @ngay DATE, @ly_do NVARCHAR(200) = N'Điều chuyển công tác'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @ls INT, @cv VARCHAR(20), @cn_cu SMALLINT, @tu DATE, @con INT;
    SELECT @ls = ma_ls, @cv = chuc_vu, @cn_cu = ma_cn, @tu = tu_ngay
    FROM dbo.LICH_SU_CONG_TAC WHERE ma_nv = @ma_nv AND den_ngay IS NULL;
    IF @ls IS NULL THROW 50050, N'Nhân viên không có giai đoạn công tác đang mở', 1;
    IF @cn_cu = @ma_cn_moi THROW 50051, N'Nhân viên đang công tác tại chi nhánh này', 1;
    IF @ngay <= @tu THROW 50052, N'Ngày điều chuyển phải sau ngày bắt đầu giai đoạn hiện tại', 1;
    IF @cv = 'PT'
    BEGIN
        SELECT @con = COUNT(*) FROM dbo.LICH_HEN_PT
         WHERE ma_hlv = @ma_nv AND ma_cn = @cn_cu AND trang_thai = 'DA_DAT' AND ngay_tap >= @ngay;
        IF @con > 0 THROW 50053, N'HLV còn lịch PT đã đặt tại chi nhánh cũ từ ngày điều chuyển. Hãy hủy/chuyển lịch trước', 1;
    END
    BEGIN TRAN;
    UPDATE dbo.LICH_SU_CONG_TAC SET den_ngay = @ngay, ly_do = @ly_do WHERE ma_ls = @ls;
    INSERT INTO dbo.LICH_SU_CONG_TAC (ma_nv, ma_cn, chuc_vu, tu_ngay, den_ngay, ly_do)
    VALUES (@ma_nv, @ma_cn_moi, @cv, @ngay, NULL, @ly_do);
    COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_CapNhatLuong @ma_nv INT, @luong_moi DECIMAL(15,0)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.NHAN_VIEN SET luong_co_ban = @luong_moi WHERE ma_nv = @ma_nv;
    IF @@ROWCOUNT = 0 THROW 50054, N'Không tìm thấy nhân viên', 1;
END;
GO

/* Hoa hồng = số buổi x (don_gia / so_buoi_pt) x ty_le_hoa_hong, nhóm theo (HLV, chi nhánh thực tế, tháng).
   Kỳ đã chốt (ngay_chot khác rỗng) không bị đổi. */
CREATE OR ALTER PROCEDURE dbo.sp_TinhHoaHongThang @thang DATE, @chot BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    SET @thang = DATEFROMPARTS(YEAR(@thang), MONTH(@thang), 1);
    DECLARE @het DATE = DATEADD(MONTH, 1, @thang);
    BEGIN TRAN;
    MERGE dbo.HOA_HONG_HLV_THANG WITH (HOLDLOCK) AS t
    USING (SELECT p.ma_hlv, p.ma_cn, COUNT(*) AS so_buoi,
                  CAST(ROUND(SUM(CAST(g.don_gia AS DECIMAL(18,4)) / d.so_buoi_pt * hl.ty_le_hoa_hong), 0) AS DECIMAL(15,0)) AS tien
           FROM dbo.LICH_HEN_PT p
           JOIN dbo.GOI_DA_MUA g ON g.ma_goi_mua = p.ma_goi_mua
           JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
           JOIN dbo.HUAN_LUYEN_VIEN hl ON hl.ma_nv = p.ma_hlv
           WHERE p.trang_thai = 'DA_HOAN_THANH' AND p.ngay_tap >= @thang AND p.ngay_tap < @het
           GROUP BY p.ma_hlv, p.ma_cn) AS s
       ON t.ma_hlv = s.ma_hlv AND t.ma_cn = s.ma_cn AND t.thang = @thang
    WHEN MATCHED AND t.ngay_chot IS NULL THEN
         UPDATE SET so_buoi_hoan_thanh = s.so_buoi, tong_hoa_hong = s.tien,
                    ngay_chot = CASE WHEN @chot = 1 THEN SYSDATETIME() END
    WHEN NOT MATCHED THEN
         INSERT (ma_hlv, ma_cn, thang, so_buoi_hoan_thanh, tong_hoa_hong, ngay_chot)
         VALUES (s.ma_hlv, s.ma_cn, @thang, s.so_buoi, s.tien, CASE WHEN @chot = 1 THEN SYSDATETIME() END);
    COMMIT;
    SELECT h.ma_hlv, nv.ho_ten, h.ma_cn, h.thang, h.so_buoi_hoan_thanh, h.tong_hoa_hong, h.ngay_chot
    FROM dbo.HOA_HONG_HLV_THANG h JOIN dbo.NHAN_VIEN nv ON nv.ma_nv = h.ma_hlv
    WHERE h.thang = @thang ORDER BY h.ma_hlv, h.ma_cn;
END;
GO

/* =====================================================================
   7. JOB ĐỊNH KỲ / ĐỐI SOÁT
   ===================================================================== */

-- Hạ hạng do cửa sổ 12 tháng trượt (vấn đề 4): chạy mỗi đêm, tối đa 12 dòng/hội viên
CREATE OR ALTER PROCEDURE dbo.sp_DonCuaSo12Thang
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @dau DATE = DATEADD(MONTH, -11, DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1));
    BEGIN TRAN;
    DELETE FROM dbo.CHI_TIEU_THANG_HV WHERE thang < @dau;
    UPDATE t SET t.tong_chi_tieu_12t = ISNULL(s.tong, 0),
                 t.ma_hang = dbo.fn_HangTheoChiTieu(ISNULL(s.tong, 0)),
                 t.ngay_xet_hang = CAST(SYSDATETIME() AS DATE)
    FROM dbo.TAI_KHOAN_LOYALTY t
    LEFT JOIN (SELECT ma_hv, SUM(tong_chi_tieu) AS tong FROM dbo.CHI_TIEU_THANG_HV GROUP BY ma_hv) s ON s.ma_hv = t.ma_hv
    WHERE t.tong_chi_tieu_12t <> ISNULL(s.tong, 0)
       OR t.ma_hang <> dbo.fn_HangTheoChiTieu(ISNULL(s.tong, 0));
    COMMIT;
END;
GO

-- Gói quá ngày hết hạn chuyển HET_HAN (QUYEN_VAO_CONG tự đồng bộ qua trigger)
CREATE OR ALTER PROCEDURE dbo.sp_CapNhatGoiHetHan
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.GOI_DA_MUA SET trang_thai = 'HET_HAN'
     WHERE trang_thai = 'HIEU_LUC' AND ngay_het_han < CAST(SYSDATETIME() AS DATE);
    SELECT @@ROWCOUNT AS so_goi_het_han;
END;
GO

-- Đối soát điểm (RB37): diem_hien_co phải bằng tổng sổ điểm; @sua = 1 thì sửa
CREATE OR ALTER PROCEDURE dbo.sp_DoiSoatDiem @sua BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.ma_hv, t.diem_hien_co AS diem_dang_luu, ISNULL(s.tong, 0) AS diem_theo_so
    INTO #lech
    FROM dbo.TAI_KHOAN_LOYALTY t
    LEFT JOIN (SELECT ma_hv, SUM(so_diem) AS tong FROM dbo.GIAO_DICH_DIEM GROUP BY ma_hv) s ON s.ma_hv = t.ma_hv
    WHERE t.diem_hien_co <> ISNULL(s.tong, 0);
    IF @sua = 1
        UPDATE t SET t.diem_hien_co = l.diem_theo_so FROM dbo.TAI_KHOAN_LOYALTY t JOIN #lech l ON l.ma_hv = t.ma_hv;
    SELECT * FROM #lech;
END;
GO

-- RB31 (đủ một quản lý tại mọi thời điểm): liệt kê chi nhánh thiếu quản lý hiện tại
CREATE OR ALTER PROCEDURE dbo.sp_KiemTraQuanLy
AS
BEGIN
    SET NOCOUNT ON;
    SELECT cn.ma_cn, cn.ten_cn
    FROM dbo.CHI_NHANH cn
    WHERE cn.trang_thai = 'HOAT_DONG'
      AND NOT EXISTS (SELECT 1 FROM dbo.LICH_SU_CONG_TAC l
                      WHERE l.ma_cn = cn.ma_cn AND l.chuc_vu = 'QUAN_LY' AND l.den_ngay IS NULL);
END;
GO

/* =====================================================================
   8. CHỈ MỤC TỐI ƯU (đồng bộ với ghi chú ở 01_create_schema.sql)
   Chạy lại an toàn (kiểm tra tồn tại trước khi tạo).
   04_scenarios.sql sẽ chủ động DROP/CREATE lại từng chỉ mục để đo trước/sau.
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_CHECKIN_open' AND object_id = OBJECT_ID(N'dbo.CHECK_IN'))
    CREATE NONCLUSTERED INDEX IX_CHECKIN_open ON dbo.CHECK_IN (ma_hv, tg_vao)
        WHERE tg_ra IS NULL AND ket_qua = 'HOP_LE'
        ON ps_checkin_thang(tg_vao);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HOA_DON_ma_hv' AND object_id = OBJECT_ID(N'dbo.HOA_DON'))
    CREATE NONCLUSTERED INDEX IX_HOA_DON_ma_hv ON dbo.HOA_DON (ma_hv)
        INCLUDE (ngay_lap, thanh_toan, trang_thai, ma_cn);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_GOI_DA_MUA_ma_hd' AND object_id = OBJECT_ID(N'dbo.GOI_DA_MUA'))
    CREATE NONCLUSTERED INDEX IX_GOI_DA_MUA_ma_hd ON dbo.GOI_DA_MUA (ma_hd)
        INCLUDE (ma_goi, trang_thai, ngay_het_han, so_buoi_con_lai, don_gia);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_LHPT_ngay_tt' AND object_id = OBJECT_ID(N'dbo.LICH_HEN_PT'))
    CREATE NONCLUSTERED INDEX IX_LHPT_ngay_tt ON dbo.LICH_HEN_PT (ngay_tap, trang_thai)
        INCLUDE (ma_hlv, ma_cn, ma_goi_mua);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_HOI_VIEN_ho_ten' AND object_id = OBJECT_ID(N'dbo.HOI_VIEN'))
    CREATE NONCLUSTERED INDEX IX_HOI_VIEN_ho_ten ON dbo.HOI_VIEN (ho_ten)
        INCLUDE (ma_the, sdt, cccd, email, gioi_tinh, ngay_sinh, ngay_dang_ky, trang_thai);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_CHECKIN_hv_tg' AND object_id = OBJECT_ID(N'dbo.CHECK_IN'))
    CREATE NONCLUSTERED INDEX IX_CHECKIN_hv_tg ON dbo.CHECK_IN (ma_hv, tg_vao)
        INCLUDE (ma_cn, ma_cua, tg_ra, ket_qua)
        ON ps_checkin_thang(tg_vao);
GO

/* =====================================================================
   KIỂM TRA NHANH (bỏ comment để chạy thử)
   =====================================================================
-- 1. Check-in (thay mã thẻ/cửa cho đúng dữ liệu của bạn)
EXEC dbo.sp_CheckIn @ma_the = 'FL0000100', @ma_cua = 1;
-- 2. Đặt lịch PT hai lần cùng khung giờ: lần 2 phải báo lỗi 50016
-- 3. Lập hóa đơn + thanh toán
DECLARE @g dbo.ds_goi, @s dbo.ds_sp, @hd BIGINT;
INSERT @g VALUES (1);
INSERT @s VALUES (1, 2);
EXEC dbo.sp_LapHoaDon @ma_hv = 100, @ma_nv_lap = 12, @ma_cn = 1,   -- nhân viên 12 = lễ tân chi nhánh 1 @goi = @g, @sp = @s, @ma_hd = @hd OUTPUT;
EXEC dbo.sp_ThanhToan @ma_hd = @hd, @hinh_thuc = 'TIEN_MAT', @so_tien = 2000000;  -- nhập đúng số can_thanh_toan
-- 4. Báo cáo
EXEC dbo.sp_BaoCaoDoanhThu 'THANG', '2026-01-01', '2026-11-30', NULL;
EXEC dbo.sp_DoiSoatDiem;
*/
