/* =====================================================================
   FitLife Hub - CSC12002 - Đồ án 2627.ADB.01 - Nhóm 2627.ADB.CLC14
   Giai đoạn 2 - Script 04: 9 kịch bản có liên quan nhau, đo "trước / sau"
   Chạy SAU 01 (schema), 02 (dữ liệu), 03 (thủ tục + trigger).

   Cách dùng: chạy TỪNG KỊCH BẢN theo thứ tự S1 -> S9 (mỗi kịch bản là một nhóm batch).
   Trong SSMS bật:  Query > Include Actual Execution Plan (Ctrl+M)  để chụp plan,
   các lệnh SET STATISTICS IO, TIME đã có sẵn trong từng kịch bản (xem tab Messages).
   Mỗi kịch bản có bước TRƯỚC (chưa có giải pháp), bước GIẢI PHÁP, bước SAU.
   Kịch bản sau có thể dùng chỉ mục do kịch bản trước tạo; đã ghi chú nơi cần chú ý.

   Mô tả 9 kịch bản (tần suất lấy từ đề bài/Phần 1):
     S1  Check-in giờ cao điểm              (> 10.000 lượt/giờ 17h-20h)     vấn đề 1
     S2  Đặt lịch PT đồng thời              (~600 lượt/ngày, dồn giờ cao điểm) vấn đề 2  -> 05_test_concurrency.py
     S3  Báo cáo doanh thu ngày/tháng/quý/năm (hàng ngày, quản lý/Ban giám đốc) vấn đề 3
     S4  Báo cáo tỷ lệ lấp đầy theo khung giờ (hàng ngày, quản lý chi nhánh)  vấn đề 3
     S5  Phân vùng CHECK_IN theo tháng và lưu trữ log                          vấn đề 3
     S6  Thanh toán, tích điểm và xét hạng  (~1.500 hóa đơn/ngày)             vấn đề 4
     S7  Hoa hồng PT khi điều chuyển chi nhánh (chốt hàng tháng)              vấn đề 5
     S8  Tra cứu hội viên theo SĐT/CCCD/mã thẻ/tên (hàng nghìn lượt/ngày)    chức năng tần suất cao
     S9  Hội viên sắp hết hạn / lâu chưa quay lại (BC06) + chi phí ghi của chỉ mục
   ===================================================================== */
USE FitLifeHub;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   Số liệu hiện có (chụp lại làm bảng "Quy mô dữ liệu" trong báo cáo)
   --------------------------------------------------------------------- */
SELECT t.name AS bang, SUM(p.rows) AS so_dong
FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY t.name ORDER BY SUM(p.rows) DESC;
GO

/* =====================================================================
   HÀM ĐO DÙNG CHUNG (chạy một lần)
   Mỗi hàm chạy trong BEGIN TRAN ... ROLLBACK nên không để lại dữ liệu rác.
   ===================================================================== */

-- Cách làm CŨ cho check-in: nối HOI_VIEN-HOA_DON-GOI_DA_MUA-GOI_DICH_VU... mỗi lượt quét,
-- đóng lượt cũ bằng cách quét CHECK_IN không giới hạn thời gian.
CREATE OR ALTER PROCEDURE dbo.sp_CheckIn_Naive @ma_the VARCHAR(30), @ma_cua SMALLINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ma_cn SMALLINT, @ma_hv INT, @gm BIGINT, @ma_checkin BIGINT, @now DATETIME2(0) = SYSDATETIME();
    SELECT @ma_cn = ma_cn FROM dbo.CUA_KIEM_SOAT WHERE ma_cua = @ma_cua;
    SELECT @ma_hv = ma_hv FROM dbo.HOI_VIEN WHERE ma_the = @ma_the AND trang_thai = 'HOAT_DONG';
    IF @ma_hv IS NULL
    BEGIN
        SELECT CAST('TU_CHOI' AS VARCHAR(10)) AS ket_qua, N'Thẻ không hợp lệ' AS ly_do, CAST(NULL AS BIGINT) AS ma_checkin;
        RETURN;
    END
    SELECT TOP (1) @gm = g.ma_goi_mua
    FROM dbo.HOI_VIEN hv
    JOIN dbo.HOA_DON h ON h.ma_hv = hv.ma_hv
    JOIN dbo.GOI_DA_MUA g ON g.ma_hd = h.ma_hd
    JOIN dbo.GOI_DICH_VU d ON d.ma_goi = g.ma_goi
    JOIN dbo.DICH_VU v ON v.ma_dv = d.ma_dv
    JOIN dbo.CN_DICH_VU c ON c.ma_cn = @ma_cn AND c.ma_dv = d.ma_dv AND c.trang_thai = 'HOAT_DONG'
    WHERE hv.ma_hv = @ma_hv AND h.trang_thai = 'DA_THANH_TOAN' AND g.trang_thai = 'HIEU_LUC'
      AND g.ngay_het_han >= CAST(@now AS DATE) AND v.nhom_dv IN ('PHONG_TAP','SPA_SAUNA')
    ORDER BY g.ngay_het_han DESC;
    IF @gm IS NOT NULL
        UPDATE dbo.CHECK_IN SET tg_ra = @now WHERE ma_hv = @ma_hv AND tg_ra IS NULL AND ket_qua = 'HOP_LE';
    INSERT INTO dbo.CHECK_IN (ma_hv, ma_cua, ma_cn, ma_goi_mua, tg_vao, tg_ra, ket_qua)
    VALUES (@ma_hv, @ma_cua, @ma_cn, @gm, @now, NULL, CASE WHEN @gm IS NULL THEN 'TU_CHOI' ELSE 'HOP_LE' END);
    SET @ma_checkin = SCOPE_IDENTITY();
    SELECT CAST(CASE WHEN @gm IS NULL THEN 'TU_CHOI' ELSE 'HOP_LE' END AS VARCHAR(10)) AS ket_qua,
           CAST(NULL AS NVARCHAR(100)) AS ly_do, @ma_checkin AS ma_checkin;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Bench_CheckIn @kieu VARCHAR(10), @n INT, @ma_cua SMALLINT = 1
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #m (id INT IDENTITY(1,1) PRIMARY KEY, ma_the VARCHAR(30) NOT NULL);
    CREATE TABLE #r (ket_qua VARCHAR(10), ly_do NVARCHAR(100), ma_checkin BIGINT);
    INSERT INTO #m (ma_the) SELECT TOP (@n) ma_the FROM dbo.HOI_VIEN WHERE trang_thai = 'HOAT_DONG' ORDER BY NEWID();
    DECLARE @i INT = 0, @max INT = (SELECT COUNT(*) FROM #m), @the VARCHAR(30), @t0 DATETIME2(7), @ms INT, @ok INT, @rej INT;
    SET @t0 = SYSDATETIME();
    BEGIN TRAN;
    WHILE @i < @max
    BEGIN
        SET @i += 1;
        SELECT @the = ma_the FROM #m WHERE id = @i;
        IF @kieu = 'NAIVE'
        BEGIN
            INSERT INTO #r EXEC dbo.sp_CheckIn_Naive @the, @ma_cua;
        END
        ELSE
        BEGIN
            INSERT INTO #r EXEC dbo.sp_CheckIn @the, @ma_cua;
        END
    END
    SET @ms = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
    SELECT @ok = SUM(CASE WHEN ket_qua = 'HOP_LE' THEN 1 ELSE 0 END),
           @rej = SUM(CASE WHEN ket_qua = 'TU_CHOI' THEN 1 ELSE 0 END) FROM #r;
    ROLLBACK;
    SELECT @kieu AS cach_lam, @max AS so_luot, @ms AS tong_ms,
           CAST(@ms * 1.0 / NULLIF(@max, 0) AS DECIMAL(10,2)) AS ms_moi_luot, @ok AS hop_le, @rej AS tu_choi;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Bench_ThanhToan @n INT
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #m (id INT IDENTITY(1,1) PRIMARY KEY, ma_hv INT NOT NULL);
    CREATE TABLE #s1 (ma_hd BIGINT, can_tt DECIMAL(15,0));
    CREATE TABLE #s2 (tt VARCHAR(15), con DECIMAL(15,0));
    INSERT INTO #m (ma_hv) SELECT TOP (@n) ma_hv FROM dbo.HOI_VIEN WHERE trang_thai = 'HOAT_DONG' ORDER BY NEWID();
    DECLARE @goi dbo.ds_goi, @sp dbo.ds_sp, @hd BIGINT, @tien DECIMAL(15,0), @hv INT, @i INT = 0,
            @max INT = (SELECT COUNT(*) FROM #m), @t0 DATETIME2(7), @ms INT,
            @nv INT = (SELECT TOP (1) ma_nv FROM dbo.LICH_SU_CONG_TAC WHERE ma_cn = 1 AND chuc_vu = 'LE_TAN' AND den_ngay IS NULL ORDER BY ma_nv),
            @sp1 INT = (SELECT TOP (1) ma_sp FROM dbo.TON_KHO WHERE ma_cn = 1 AND so_luong_ton >= 100 ORDER BY ma_sp);
    INSERT INTO @goi VALUES (1);              -- Gym 3 tháng (bán ở mọi chi nhánh)
    INSERT INTO @sp VALUES (@sp1, 1);
    SET @t0 = SYSDATETIME();
    BEGIN TRAN;
    WHILE @i < @max
    BEGIN
        SET @i += 1;
        SELECT @hv = ma_hv FROM #m WHERE id = @i;
        INSERT INTO #s1 EXEC dbo.sp_LapHoaDon @ma_hv = @hv, @ma_nv_lap = @nv, @ma_cn = 1, @goi = @goi, @sp = @sp, @ma_hd = @hd OUTPUT;
        SELECT @tien = thanh_toan FROM dbo.HOA_DON WHERE ma_hd = @hd;
        INSERT INTO #s2 EXEC dbo.sp_ThanhToan @ma_hd = @hd, @hinh_thuc = 'TIEN_MAT', @so_tien = @tien;
    END
    SET @ms = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
    ROLLBACK;
    SELECT @max AS so_hoa_don, @ms AS tong_ms, CAST(@ms * 1.0 / NULLIF(@max, 0) AS DECIMAL(10,2)) AS ms_moi_hoa_don;
END;
GO

/* =====================================================================
   S1 - CHECK-IN GIỜ CAO ĐIỂM (vấn đề 1)
   Mục tiêu: xác thực hội viên + ghi log < 50 ms ở hơn 10.000 lượt/giờ.
   Giải pháp: bảng QUYEN_VAO_CONG (1 dòng/hội viên/dịch vụ, tra theo khóa chính),
              CHECK_IN chỉ chèn cuối bảng, chỉ mục lọc nhỏ cho lượt chưa check-out.
   ===================================================================== */

-- S1.1 TRƯỚC: cách nối nhiều bảng lớn, chưa có chỉ mục hỗ trợ (chỉ 20 lượt vì rất chậm)
DROP INDEX IF EXISTS IX_CHECKIN_open ON dbo.CHECK_IN;
DROP INDEX IF EXISTS IX_HOA_DON_ma_hv ON dbo.HOA_DON;
DROP INDEX IF EXISTS IX_GOI_DA_MUA_ma_hd ON dbo.GOI_DA_MUA;
GO
SET STATISTICS IO, TIME OFF;
EXEC dbo.sp_Bench_CheckIn @kieu = 'NAIVE', @n = 20;
GO

-- S1.2 Xem logical reads của MỘT lượt (chụp execution plan ở đây)
SET STATISTICS IO, TIME ON;
DECLARE @the VARCHAR(30) = (SELECT TOP (1) ma_the FROM dbo.HOI_VIEN WHERE trang_thai = 'HOAT_DONG' ORDER BY ma_hv DESC);
BEGIN TRAN;
EXEC dbo.sp_CheckIn_Naive @the, 1;
ROLLBACK;
SET STATISTICS IO, TIME OFF;
GO

-- S1.3 GIẢI PHÁP: chỉ mục lọc (rất nhỏ) cho lượt đang mở, căn theo phân vùng của CHECK_IN
CREATE NONCLUSTERED INDEX IX_CHECKIN_open ON dbo.CHECK_IN (ma_hv, tg_vao)
    WHERE tg_ra IS NULL AND ket_qua = 'HOP_LE'
    ON ps_checkin_thang(tg_vao);
-- (QUYEN_VAO_CONG, UQ ma_the của HOI_VIEN, PK của CN_DICH_VU đã có từ script 01/02)
GO

-- S1.4 SAU: quy trình mới, 2.000 lượt
SET STATISTICS IO, TIME OFF;
EXEC dbo.sp_Bench_CheckIn @kieu = 'MOI', @n = 2000;
GO

SET STATISTICS IO, TIME ON;
DECLARE @the VARCHAR(30) = (SELECT TOP (1) ma_the FROM dbo.HOI_VIEN WHERE trang_thai = 'HOAT_DONG' ORDER BY ma_hv DESC);
BEGIN TRAN;
EXEC dbo.sp_CheckIn @the, 1;
ROLLBACK;
SET STATISTICS IO, TIME OFF;
GO
-- Kiểm chứng tải ĐỒNG THỜI (nhiều kết nối, p50/p95/p99): chạy  python 05_test_concurrency.py checkin

/* =====================================================================
   S2 - ĐẶT LỊCH PT ĐỒNG THỜI (vấn đề 2)
   Giải pháp: UNIQUE có lọc (RB12) + trừ buổi bằng UPDATE có điều kiện (sp_DatLichPT).
   Cách làm cũ: kiểm tra "SELECT ... NOT EXISTS" rồi INSERT => hai giao dịch cùng thấy trống.
   Cần kết nối song song nên kiểm chứng bằng Python:
       python 05_test_concurrency.py overbook --mode naive    # TRƯỚC: bỏ UNIQUE, cách cũ  => có lịch trùng
       python 05_test_concurrency.py overbook --mode safe     # SAU : sp_DatLichPT         => 0 lịch trùng
   Script Python tự bỏ/tạo lại hai chỉ mục UNIQUE và dọn dữ liệu thử.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.sp_DatLichPT_Naive
    @ma_hv INT, @ma_goi_mua BIGINT, @ma_hlv INT, @ngay_tap DATE, @ma_khung_gio TINYINT, @tre_ms INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ma_cn SMALLINT = (SELECT TOP (1) ma_cn FROM dbo.LICH_SU_CONG_TAC
                               WHERE ma_nv = @ma_hlv AND chuc_vu = 'PT' AND tu_ngay <= @ngay_tap AND (den_ngay IS NULL OR @ngay_tap < den_ngay));
    -- bước 1: kiểm tra khung giờ còn trống (đọc, không khóa)
    IF EXISTS (SELECT 1 FROM dbo.LICH_HEN_PT WHERE ma_hlv = @ma_hlv AND ngay_tap = @ngay_tap
                  AND ma_khung_gio = @ma_khung_gio AND trang_thai <> 'DA_HUY')
        THROW 50099, N'Khung giờ đã có người đặt', 1;
    DECLARE @d VARCHAR(12) = '00:00:00.' + RIGHT('000' + CAST(@tre_ms AS VARCHAR(3)), 3);
    WAITFOR DELAY @d;                                -- mô phỏng độ trễ giữa kiểm tra và ghi
    -- bước 2: ghi
    INSERT INTO dbo.LICH_HEN_PT (ma_hv, ma_hlv, ma_cn, ma_goi_mua, ngay_tap, ma_khung_gio)
    VALUES (@ma_hv, @ma_hlv, @ma_cn, @ma_goi_mua, @ngay_tap, @ma_khung_gio);
END;
GO

/* =====================================================================
   S3 - BÁO CÁO DOANH THU THEO NGÀY/THÁNG/QUÝ/NĂM (vấn đề 3)
   Giải pháp: bảng tổng hợp TH_DOANH_THU_NGAY, cộng gia tăng bằng trigger khi hóa đơn thanh toán/hủy.
   ===================================================================== */
SET STATISTICS IO, TIME ON;
DECLARE @tu DATETIME2(0) = DATEADD(MONTH, -11, DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1)),
        @den DATETIME2(0) = DATEADD(DAY, 1, CAST(SYSDATETIME() AS DATE));
-- S3.1 TRƯỚC: quét bảng hóa đơn (~540.000 dòng/năm)
SELECT DATEFROMPARTS(YEAR(ngay_lap), MONTH(ngay_lap), 1) AS thang, COUNT(*) AS so_hoa_don, SUM(thanh_toan) AS doanh_thu
FROM dbo.HOA_DON
WHERE trang_thai = 'DA_THANH_TOAN' AND ngay_lap >= @tu AND ngay_lap < @den
GROUP BY DATEFROMPARTS(YEAR(ngay_lap), MONTH(ngay_lap), 1)
ORDER BY thang;
GO
-- S3.2 SAU: đọc bảng tổng hợp (~4.400 dòng/năm cho 12 chi nhánh)
DECLARE @tu DATE = DATEADD(MONTH, -11, DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1)),
        @den DATE = CAST(SYSDATETIME() AS DATE);
EXEC dbo.sp_BaoCaoDoanhThu @cap = 'THANG', @tu = @tu, @den = @den;
EXEC dbo.sp_BaoCaoDoanhThu @cap = 'QUY',   @tu = @tu, @den = @den;
SET STATISTICS IO, TIME OFF;
GO
-- S3.3 Đối chiếu: hai cách phải ra cùng tổng (nếu khác => dữ liệu tổng hợp lệch)
SELECT (SELECT SUM(thanh_toan) FROM dbo.HOA_DON WHERE trang_thai = 'DA_THANH_TOAN') AS tong_tu_hoa_don,
       (SELECT SUM(doanh_thu_goi + doanh_thu_san_pham) FROM dbo.TH_DOANH_THU_NGAY) AS tong_tu_bang_tong_hop;
GO

/* =====================================================================
   S4 - BÁO CÁO LẤP ĐẦY THEO KHUNG GIỜ (vấn đề 3)
   Giải pháp: TH_LAP_DAY_GIO (chi nhánh, ngày, giờ) nạp từ CHECK_IN bằng sp_NapLapDayGio.
   ===================================================================== */
SET STATISTICS IO, TIME ON;
DECLARE @cn SMALLINT = 1, @t0 DATETIME2(0) = DATEADD(YEAR, -1, CAST(SYSDATETIME() AS DATE)), @t1 DATETIME2(0) = CAST(SYSDATETIME() AS DATE);
-- S4.1 TRƯỚC: đếm lượt vào theo giờ từ log thô, cả năm (quét ~2,6 triệu dòng)
SELECT DATEPART(HOUR, tg_vao) AS gio, COUNT(*) AS luot_vao
FROM dbo.CHECK_IN
WHERE ma_cn = @cn AND ket_qua = 'HOP_LE' AND tg_vao >= @t0 AND tg_vao < @t1
GROUP BY DATEPART(HOUR, tg_vao) ORDER BY gio;
GO
-- S4.2 SAU: đọc bảng tổng hợp
DECLARE @tu DATE = DATEADD(YEAR, -1, CAST(SYSDATETIME() AS DATE)), @den DATE = CAST(SYSDATETIME() AS DATE);
EXEC dbo.sp_BaoCaoLapDay @ma_cn = 1, @tu = @tu, @den = @den;
SET STATISTICS IO, TIME OFF;
GO
-- S4.3 Nạp lại một ngày bằng thủ tục (job chạy mỗi giờ/đêm); xem thời gian nạp một ngày
SET STATISTICS TIME ON;
DECLARE @h DATE = DATEADD(DAY, -2, CAST(SYSDATETIME() AS DATE));
EXEC dbo.sp_NapLapDayGio @ngay = @h;
SET STATISTICS TIME OFF;
GO

/* =====================================================================
   S5 - PHÂN VÙNG CHECK_IN THEO THÁNG (vấn đề 3)
   So sánh trên BẢN SAO (không đụng bảng thật):
     CHECK_IN_NP : cùng khóa cụm (tg_vao, ma_checkin) nhưng KHÔNG phân vùng
     CHECK_IN_P  : phân vùng theo tháng (cùng scheme với CHECK_IN)
   Trung thực về kết quả: với khóa cụm bắt đầu bằng tg_vao, truy vấn theo khoảng thời gian đều
   "seek" được cả hai cách; lợi ích rõ nhất của phân vùng là LƯU TRỮ (SWITCH) và bảo trì theo tháng.
   ===================================================================== */
DROP TABLE IF EXISTS dbo.CHECK_IN_NP, dbo.CHECK_IN_P, dbo.CHECK_IN_ARCH;
GO
SELECT * INTO dbo.CHECK_IN_NP FROM dbo.CHECK_IN;
SELECT * INTO dbo.CHECK_IN_P  FROM dbo.CHECK_IN;
SELECT * INTO dbo.CHECK_IN_ARCH FROM dbo.CHECK_IN WHERE 1 = 0;
GO
CREATE UNIQUE CLUSTERED INDEX CX_CHECK_IN_NP ON dbo.CHECK_IN_NP (tg_vao, ma_checkin) ON [PRIMARY];
CREATE UNIQUE CLUSTERED INDEX CX_CHECK_IN_P  ON dbo.CHECK_IN_P  (tg_vao, ma_checkin) ON ps_checkin_thang(tg_vao);
CREATE UNIQUE CLUSTERED INDEX CX_CHECK_IN_ARCH ON dbo.CHECK_IN_ARCH (tg_vao, ma_checkin) ON [PRIMARY];
GO

-- S5.1 Số dòng theo partition (chụp vào báo cáo)
SELECT $PARTITION.pf_checkin_thang(tg_vao) AS so_partition, MIN(tg_vao) AS tu, MAX(tg_vao) AS den, COUNT(*) AS so_dong
FROM dbo.CHECK_IN_P GROUP BY $PARTITION.pf_checkin_thang(tg_vao) ORDER BY so_partition;
GO

-- S5.2 Truy vấn một tháng: phân vùng (partition elimination) và không phân vùng
SET STATISTICS IO, TIME ON;
DECLARE @t0 DATETIME2(0) = DATEFROMPARTS(YEAR(DATEADD(MONTH, -3, SYSDATETIME())), MONTH(DATEADD(MONTH, -3, SYSDATETIME())), 1),
        @t1 DATETIME2(0);
SET @t1 = DATEADD(MONTH, 1, @t0);
SELECT ma_cn, COUNT(*) AS luot FROM dbo.CHECK_IN_NP WHERE tg_vao >= @t0 AND tg_vao < @t1 AND ket_qua = 'HOP_LE' GROUP BY ma_cn;
SELECT ma_cn, COUNT(*) AS luot FROM dbo.CHECK_IN_P  WHERE tg_vao >= @t0 AND tg_vao < @t1 AND ket_qua = 'HOP_LE' GROUP BY ma_cn;
SET STATISTICS IO, TIME OFF;
GO
-- (Trong Actual Execution Plan của câu thứ hai: Clustered Index Seek > Properties > "Actual Partition Count = 1")

-- S5.3 Lưu trữ log của tháng CŨ NHẤT: DELETE (không phân vùng) và SWITCH (phân vùng)
DECLARE @thang DATETIME2(0) = (SELECT DATEFROMPARTS(YEAR(MIN(tg_vao)), MONTH(MIN(tg_vao)), 1) FROM dbo.CHECK_IN_P),
        @t0 DATETIME2(7), @ms1 INT, @ms2 INT, @n1 INT, @n2 INT, @pn INT;
DECLARE @den DATETIME2(0) = DATEADD(MONTH, 1, @thang);
SET @pn = $PARTITION.pf_checkin_thang(@thang);
SELECT @n1 = COUNT(*) FROM dbo.CHECK_IN_NP WHERE tg_vao >= @thang AND tg_vao < @den;

SET @t0 = SYSDATETIME();
DELETE FROM dbo.CHECK_IN_NP WHERE tg_vao >= @thang AND tg_vao < @den;      -- cách thường: ghi log từng dòng
SET @ms1 = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());

SET @t0 = SYSDATETIME();
ALTER TABLE dbo.CHECK_IN_P SWITCH PARTITION @pn TO dbo.CHECK_IN_ARCH;      -- chỉ đổi metadata
SET @ms2 = DATEDIFF(MILLISECOND, @t0, SYSDATETIME());
SELECT @n2 = COUNT(*) FROM dbo.CHECK_IN_ARCH;

SELECT @thang AS thang_luu_tru, @n1 AS so_dong_thang, @ms1 AS delete_ms, @ms2 AS switch_ms, @n2 AS dong_da_chuyen_sang_kho;
GO
-- Dọn bản sao (giữ lại nếu cần chụp plan; xóa khi xong S5)
-- DROP TABLE dbo.CHECK_IN_NP, dbo.CHECK_IN_P, dbo.CHECK_IN_ARCH;
GO

/* =====================================================================
   S6 - THANH TOÁN, TÍCH ĐIỂM VÀ XÉT HẠNG (vấn đề 4)
   Cách cũ: mỗi lần thanh toán cộng lại tổng hóa đơn 12 tháng của hội viên.
   Giải pháp: cộng dồn trên TAI_KHOAN_LOYALTY + CHI_TIEU_THANG_HV, sổ điểm bất biến (trigger).
   Ba mức đo: (a) cộng lại 12 tháng, chưa có chỉ mục; (b) cộng lại 12 tháng, có chỉ mục;
              (c) đọc một dòng loyalty. Rồi đo cả giao dịch lập hóa đơn + thanh toán.
   ===================================================================== */
DROP INDEX IF EXISTS IX_HOA_DON_ma_hv ON dbo.HOA_DON;
DROP INDEX IF EXISTS IX_GOI_DA_MUA_ma_hd ON dbo.GOI_DA_MUA;
GO
SET STATISTICS IO, TIME ON;
DECLARE @hv INT = (SELECT TOP (1) ma_hv FROM dbo.HOA_DON WHERE ma_hv IS NOT NULL GROUP BY ma_hv ORDER BY COUNT(*) DESC),
        @tu DATETIME2(0) = DATEADD(MONTH, -12, SYSDATETIME());
-- S6.1 (a) TRƯỚC: cộng lại 12 tháng hóa đơn, chưa có chỉ mục trên HOA_DON(ma_hv)
SELECT SUM(thanh_toan) AS chi_tieu_12_thang FROM dbo.HOA_DON
WHERE ma_hv = @hv AND trang_thai = 'DA_THANH_TOAN' AND ngay_lap >= @tu;
GO
-- S6.2 Chỉ mục nền cho khóa ngoại (cần cả cho trigger của GOI_DA_MUA/HOA_DON và màn hình tra cứu)
CREATE NONCLUSTERED INDEX IX_HOA_DON_ma_hv ON dbo.HOA_DON (ma_hv)
    INCLUDE (ngay_lap, thanh_toan, trang_thai, ma_cn);
CREATE NONCLUSTERED INDEX IX_GOI_DA_MUA_ma_hd ON dbo.GOI_DA_MUA (ma_hd)
    INCLUDE (ma_goi, trang_thai, ngay_het_han, so_buoi_con_lai, don_gia);
GO
SET STATISTICS IO, TIME ON;
DECLARE @hv INT = (SELECT TOP (1) ma_hv FROM dbo.HOA_DON WHERE ma_hv IS NOT NULL GROUP BY ma_hv ORDER BY COUNT(*) DESC),
        @tu DATETIME2(0) = DATEADD(MONTH, -12, SYSDATETIME());
-- (b) cộng lại 12 tháng, đã có chỉ mục
SELECT SUM(thanh_toan) AS chi_tieu_12_thang FROM dbo.HOA_DON
WHERE ma_hv = @hv AND trang_thai = 'DA_THANH_TOAN' AND ngay_lap >= @tu;
-- (c) SAU: đọc đúng một dòng loyalty
SELECT tong_chi_tieu_12t, ma_hang, diem_hien_co FROM dbo.TAI_KHOAN_LOYALTY WHERE ma_hv = @hv;
SET STATISTICS IO, TIME OFF;
GO
-- S6.3 Đo giao dịch hoàn chỉnh "lập hóa đơn + thanh toán" (gồm trigger kích hoạt gói, tích điểm,
--      nâng hạng, cộng bảng tổng hợp). 300 hóa đơn, ROLLBACK cuối cùng.
EXEC dbo.sp_Bench_ThanhToan @n = 300;
GO
-- S6.4 Đối soát: điểm lưu = tổng sổ điểm (RB37). Kết quả mong đợi: 0 dòng lệch
EXEC dbo.sp_DoiSoatDiem @sua = 0;
GO
-- S6.5 Phân bố hạng
EXEC dbo.sp_PhanBoHangHoiVien;
GO

/* =====================================================================
   S7 - HOA HỒNG PT KHI ĐIỀU CHUYỂN CHI NHÁNH (vấn đề 5)
   Cách cũ: lưu "chi nhánh hiện tại" của nhân viên -> điều chuyển ghi đè, hoa hồng của tháng bị
   tính sai chi nhánh. Giải pháp: LICH_SU_CONG_TAC theo khoảng thời gian + LICH_HEN_PT.ma_cn lưu
   chi nhánh thực tế của buổi tập + HOA_HONG_HLV_THANG chốt theo (HLV, chi nhánh, tháng).
   ===================================================================== */
-- S7.1 TRƯỚC (minh họa sai lệch): nếu gán buổi tập theo chi nhánh "hiện tại" của HLV
SELECT COUNT(*) AS buoi_tinh_sai_chi_nhanh,
       COUNT(DISTINCT p.ma_hlv) AS so_hlv_bi_anh_huong
FROM dbo.LICH_HEN_PT p
JOIN dbo.LICH_SU_CONG_TAC cur ON cur.ma_nv = p.ma_hlv AND cur.den_ngay IS NULL
WHERE p.trang_thai = 'DA_HOAN_THANH' AND p.ma_cn <> cur.ma_cn;
GO
-- S7.2 Một HLV bị điều chuyển: lịch sử công tác và số buổi dạy theo từng chi nhánh
DECLARE @nv INT = (SELECT TOP (1) ma_nv FROM dbo.LICH_SU_CONG_TAC WHERE chuc_vu = 'PT' AND ly_do = N'Điều chuyển công tác' AND den_ngay IS NOT NULL ORDER BY ma_nv);
SELECT ma_ls, ma_nv, ma_cn, chuc_vu, tu_ngay, den_ngay FROM dbo.LICH_SU_CONG_TAC WHERE ma_nv = @nv ORDER BY tu_ngay;
SELECT p.ma_cn, COUNT(*) AS so_buoi_hoan_thanh FROM dbo.LICH_HEN_PT p
WHERE p.ma_hlv = @nv AND p.trang_thai = 'DA_HOAN_THANH' GROUP BY p.ma_cn;
-- cách mới: hoa hồng đã chốt theo (chi nhánh, tháng)
SELECT ma_cn, thang, so_buoi_hoan_thanh, tong_hoa_hong FROM dbo.HOA_HONG_HLV_THANG WHERE ma_hlv = @nv ORDER BY thang, ma_cn;
GO
-- S7.3 Tính hoa hồng một tháng: TRƯỚC chỉ mục (quét LICH_HEN_PT) ...
DROP INDEX IF EXISTS IX_LHPT_ngay_tt ON dbo.LICH_HEN_PT;
GO
SET STATISTICS IO, TIME ON;
DECLARE @thang DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1));
EXEC dbo.sp_TinhHoaHongThang @thang = @thang, @chot = 0;   -- tháng đã chốt thì MERGE không đổi gì, chỉ đo thời gian
SET STATISTICS IO, TIME OFF;
GO
-- ... giải pháp: chỉ mục phục vụ tính hoa hồng theo tháng
CREATE NONCLUSTERED INDEX IX_LHPT_ngay_tt ON dbo.LICH_HEN_PT (ngay_tap, trang_thai)
    INCLUDE (ma_hlv, ma_cn, ma_goi_mua);
GO
-- ... SAU
SET STATISTICS IO, TIME ON;
DECLARE @thang DATE = DATEADD(MONTH, -1, DATEFROMPARTS(YEAR(SYSDATETIME()), MONTH(SYSDATETIME()), 1));
EXEC dbo.sp_TinhHoaHongThang @thang = @thang, @chot = 0;
SET STATISTICS IO, TIME OFF;
GO
-- S7.4 Thử điều chuyển bằng thủ tục: nếu HLV còn lịch đã đặt ở chi nhánh cũ, thủ tục từ chối (RB34)
-- EXEC dbo.sp_DieuChuyenNhanVien @ma_nv = 2, @ma_cn_moi = 5, @ngay = '2026-12-01';

/* =====================================================================
   S8 - TRA CỨU HỘI VIÊN (SĐT / CCCD / mã thẻ / tên)
   SĐT, CCCD, mã thẻ đã có chỉ mục UNIQUE (RB10). Tên chưa có => tìm theo tiền tố tên quét cả bảng.
   ===================================================================== */
DROP INDEX IF EXISTS IX_HOI_VIEN_ho_ten ON dbo.HOI_VIEN;
GO
SET STATISTICS IO, TIME ON;
DECLARE @sdt NVARCHAR(100) = (SELECT TOP (1) sdt FROM dbo.HOI_VIEN ORDER BY ma_hv DESC);
EXEC dbo.sp_TraCuuHoiVien @tu_khoa = @sdt;                 -- seek theo UNIQUE(sdt)
DECLARE @ten NVARCHAR(100) = (SELECT TOP (1) LEFT(ho_ten, CHARINDEX(N' ', ho_ten + N' ') - 1) FROM dbo.HOI_VIEN ORDER BY ma_hv DESC);
EXEC dbo.sp_TraCuuHoiVien @tu_khoa = @ten;                 -- TRƯỚC: tìm theo tiền tố tên
SET STATISTICS IO, TIME OFF;
GO
CREATE NONCLUSTERED INDEX IX_HOI_VIEN_ho_ten ON dbo.HOI_VIEN (ho_ten)
    INCLUDE (ma_the, sdt, cccd, email, gioi_tinh, ngay_sinh, ngay_dang_ky, trang_thai);
GO
SET STATISTICS IO, TIME ON;
DECLARE @ten NVARCHAR(100) = (SELECT TOP (1) LEFT(ho_ten, CHARINDEX(N' ', ho_ten + N' ') - 1) FROM dbo.HOI_VIEN ORDER BY ma_hv DESC);
EXEC dbo.sp_TraCuuHoiVien @tu_khoa = @ten;                 -- SAU
SET STATISTICS IO, TIME OFF;
GO

/* =====================================================================
   S9 - HỘI VIÊN SẮP HẾT HẠN / LÂU CHƯA QUAY LẠI (BC06) VÀ CHI PHÍ GHI CỦA CHỈ MỤC
   Truy vấn cần "hội viên X có check-in trong 30 ngày qua không" => cần CHECK_IN(ma_hv, tg_vao).
   Chỉ mục này cũng phục vụ tra cứu lịch sử tập của hội viên (sp_LichSuTap).
   Nhưng CHECK_IN là bảng ghi nóng => đo lại chi phí check-in sau khi thêm chỉ mục (đánh đổi).
   ===================================================================== */
DROP INDEX IF EXISTS IX_CHECKIN_hv_tg ON dbo.CHECK_IN;
GO
-- S9.1 TRƯỚC
SET STATISTICS IO, TIME ON;
EXEC dbo.sp_HoiVienSapHetHan @ma_cn = 1, @so_ngay_het_han = 14, @so_ngay_vang = 30;
DECLARE @hv INT = (SELECT TOP (1) ma_hv FROM dbo.CHECK_IN ORDER BY tg_vao DESC);
EXEC dbo.sp_LichSuTap @ma_hv = @hv;
SET STATISTICS IO, TIME OFF;
GO
SET STATISTICS IO, TIME OFF;
EXEC dbo.sp_Bench_CheckIn @kieu = 'MOI', @n = 2000;          -- chi phí check-in KHI CHƯA có chỉ mục S9
GO
-- S9.2 GIẢI PHÁP
CREATE NONCLUSTERED INDEX IX_CHECKIN_hv_tg ON dbo.CHECK_IN (ma_hv, tg_vao) INCLUDE (ma_cn, ma_cua, tg_ra, ket_qua)
    ON ps_checkin_thang(tg_vao);
GO
-- S9.3 SAU
SET STATISTICS IO, TIME ON;
EXEC dbo.sp_HoiVienSapHetHan @ma_cn = 1, @so_ngay_het_han = 14, @so_ngay_vang = 30;
DECLARE @hv INT = (SELECT TOP (1) ma_hv FROM dbo.CHECK_IN ORDER BY tg_vao DESC);
EXEC dbo.sp_LichSuTap @ma_hv = @hv;
SET STATISTICS IO, TIME OFF;
GO
SET STATISTICS IO, TIME OFF;
EXEC dbo.sp_Bench_CheckIn @kieu = 'MOI', @n = 2000;          -- chi phí check-in SAU khi có chỉ mục S9 => ghi vào bảng so sánh
GO

/* =====================================================================
   KIỂM TRA RÀNG BUỘC (đưa vào báo cáo như bằng chứng cho RB12, RB26, RB35, RB40...)
   Mỗi câu dưới đây PHẢI báo lỗi (dùng BEGIN TRY để in thông báo thay vì dừng script).
   ===================================================================== */
BEGIN TRY
    DELETE TOP (1) FROM dbo.HOA_DON;
END TRY
BEGIN CATCH
    SELECT 'RB40 - xóa hóa đơn' AS rang_buoc, ERROR_NUMBER() AS ma_loi, ERROR_MESSAGE() AS thong_bao;
END CATCH;
GO
BEGIN TRY
    UPDATE TOP (1) dbo.GIAO_DICH_DIEM SET so_diem = so_diem + 1;
END TRY
BEGIN CATCH
    SELECT 'RB37 - sửa sổ điểm' AS rang_buoc, ERROR_NUMBER() AS ma_loi, ERROR_MESSAGE() AS thong_bao;
END CATCH;
GO
BEGIN TRY
    BEGIN TRAN;
    UPDATE TOP (1) dbo.HOA_DON SET trang_thai = 'DA_THANH_TOAN' WHERE trang_thai = 'CHO_THANH_TOAN';  -- không có thanh toán khớp
    ROLLBACK;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT 'RB26 - DA_THANH_TOAN khi chưa đủ tiền' AS rang_buoc, ERROR_NUMBER() AS ma_loi, ERROR_MESSAGE() AS thong_bao;
END CATCH;
GO
BEGIN TRY
    INSERT INTO dbo.HANG_THANH_VIEN (ma_hang, ten_hang, nguong_chi_tieu) VALUES (4, 'DIAMOND', 100);   -- ngưỡng thấp hơn hạng 3
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT 'RB24 - ngưỡng hạng không tăng dần' AS rang_buoc, ERROR_NUMBER() AS ma_loi, ERROR_MESSAGE() AS thong_bao;
END CATCH;
GO

/* =====================================================================
   DỌN DẸP (tùy chọn): xóa thủ tục đo và bảng bản sao S5
   ===================================================================== */
-- DROP PROCEDURE IF EXISTS dbo.sp_Bench_CheckIn, dbo.sp_Bench_ThanhToan, dbo.sp_CheckIn_Naive, dbo.sp_DatLichPT_Naive;
-- DROP TABLE IF EXISTS dbo.CHECK_IN_NP, dbo.CHECK_IN_P, dbo.CHECK_IN_ARCH;
