/* =====================================================================
   FitLife Hub - CSC12002 - Đồ án 2627.ADB.01 - Nhóm 2627.ADB.CLC14
   Giai đoạn 2 - Script 01: tạo CSDL, 22 bảng lõi + 6 bảng dẫn xuất
   DBMS: SQL Server 2016+ (cần bản Developer/Enterprise để dùng partition;
         nếu dùng Express, xem ghi chú ở bảng CHECK_IN)
   Quy ước: bảng UPPER_SNAKE, cột lower_snake, tiền DECIMAL(15,0),
            thời điểm DATETIME2(0). Mã ràng buộc RBxx theo Phần 2, mục 3.
   Script này CHỈ tạo các index do PK/UNIQUE/FK-lọc yêu cầu (baseline).
   Các index tối ưu (covering, filtered phục vụ báo cáo...) để script 03,
   nhằm đo được "trước/sau" cho từng kịch bản.
   ===================================================================== */

-- Xóa hẳn database cũ (nếu có) rồi tạo mới: sạch nhất, không phụ thuộc trạng thái trước đó.
-- CẢNH BÁO: mất toàn bộ dữ liệu trong FitLifeHub. Chạy từ master để không "đứng" trong DB đang xóa.
USE master;
GO
IF DB_ID(N'FitLifeHub') IS NOT NULL
BEGIN
    ALTER DATABASE FitLifeHub SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE FitLifeHub;
END
GO
CREATE DATABASE FitLifeHub;
GO
USE FitLifeHub;
GO

/* ---------------------------------------------------------------------
   0. DỌN (chạy lại được nhiều lần) - xóa theo thứ tự ngược của FK
   --------------------------------------------------------------------- */
-- CẢNH BÁO: khối này xóa MỌI khóa ngoại và MỌI bảng của schema dbo trong
-- database FitLifeHub (kể cả bảng thừa từ các lần chạy thử trước).
-- Chỉ dùng cho database dành riêng cho đồ án này.
DECLARE @sql NVARCHAR(MAX) = N'';

-- (a) xóa toàn bộ khóa ngoại trước, để thứ tự xóa bảng không còn quan trọng
SELECT @sql += N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(parent_object_id))
             + N'.' + QUOTENAME(OBJECT_NAME(parent_object_id))
             + N' DROP CONSTRAINT ' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.foreign_keys;
EXEC (@sql);

-- (b) xóa toàn bộ bảng người dùng
SET @sql = N'';
SELECT @sql += N'DROP TABLE ' + QUOTENAME(SCHEMA_NAME(schema_id))
             + N'.' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.tables;
EXEC (@sql);
GO
IF EXISTS (SELECT 1 FROM sys.partition_schemes WHERE name = N'ps_checkin_thang')
    DROP PARTITION SCHEME ps_checkin_thang;
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'pf_checkin_thang')
    DROP PARTITION FUNCTION pf_checkin_thang;
GO

/* ---------------------------------------------------------------------
   1. PHÂN VÙNG CHECK_IN THEO THÁNG (vấn đề 3)
      RANGE RIGHT, mỗi tháng một partition, từ 2025-01 đến 2027-01.
      Dữ liệu ngoài khoảng rơi vào partition đầu/cuối (không lỗi).
      Nếu dùng SQL Server Express: bỏ khối này và đổi
      "ON ps_checkin_thang(tg_vao)" ở bảng CHECK_IN thành "ON [PRIMARY]".
   --------------------------------------------------------------------- */
DECLARE @d DATE = '2025-01-01', @list NVARCHAR(MAX) = N'';
WHILE @d <= '2027-01-01'
BEGIN
    SET @list += CASE WHEN @list = N'' THEN N'' ELSE N',' END
               + N'''' + CONVERT(NVARCHAR(10), @d, 23) + N'''';
    SET @d = DATEADD(MONTH, 1, @d);
END
EXEC (N'CREATE PARTITION FUNCTION pf_checkin_thang (DATETIME2(0)) '
    + N'AS RANGE RIGHT FOR VALUES (' + @list + N')');
GO
CREATE PARTITION SCHEME ps_checkin_thang
    AS PARTITION pf_checkin_thang ALL TO ([PRIMARY]);
GO

/* =====================================================================
   PHÂN HỆ A - TỔ CHỨC VÀ NHÂN SỰ
   ===================================================================== */

CREATE TABLE CHI_NHANH (
    ma_cn      SMALLINT      IDENTITY(1,1) NOT NULL,
    ten_cn     NVARCHAR(100) NOT NULL,
    dia_chi    NVARCHAR(200) NOT NULL,
    thanh_pho  NVARCHAR(50)  NOT NULL,
    sdt        VARCHAR(15)   NOT NULL,
    gio_mo     TIME(0)       NOT NULL,
    gio_dong   TIME(0)       NOT NULL,
    trang_thai VARCHAR(15)   NOT NULL CONSTRAINT DF_CHI_NHANH_trang_thai DEFAULT 'HOAT_DONG',
    CONSTRAINT PK_CHI_NHANH PRIMARY KEY (ma_cn),
    CONSTRAINT UQ_CHI_NHANH_ten_cn UNIQUE (ten_cn),
    CONSTRAINT CK_CHI_NHANH_sdt        CHECK (sdt NOT LIKE '%[^0-9]%'),
    CONSTRAINT CK_CHI_NHANH_gio        CHECK (gio_mo < gio_dong),                         -- RB15
    CONSTRAINT CK_CHI_NHANH_trang_thai CHECK (trang_thai IN ('HOAT_DONG','TAM_DONG','DONG_CUA')) -- RB01
);
GO

CREATE TABLE DICH_VU (
    ma_dv    SMALLINT      IDENTITY(1,1) NOT NULL,
    ten_dv   NVARCHAR(50)  NOT NULL,
    nhom_dv  VARCHAR(15)   NOT NULL,
    mo_ta    NVARCHAR(200) NULL,
    CONSTRAINT PK_DICH_VU PRIMARY KEY (ma_dv),
    CONSTRAINT UQ_DICH_VU_ten_dv UNIQUE (ten_dv),
    CONSTRAINT CK_DICH_VU_nhom_dv CHECK (nhom_dv IN ('PHONG_TAP','PT','SPA_SAUNA','CUA_HANG')) -- RB01
);
GO

CREATE TABLE CN_DICH_VU (
    ma_cn      SMALLINT    NOT NULL,
    ma_dv      SMALLINT    NOT NULL,
    suc_chua   SMALLINT    NULL,      -- NULL = không giới hạn (PT, cửa hàng)
    trang_thai VARCHAR(15) NOT NULL CONSTRAINT DF_CN_DICH_VU_trang_thai DEFAULT 'HOAT_DONG',
    CONSTRAINT PK_CN_DICH_VU PRIMARY KEY (ma_cn, ma_dv),
    CONSTRAINT FK_CN_DICH_VU_CHI_NHANH FOREIGN KEY (ma_cn) REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT FK_CN_DICH_VU_DICH_VU   FOREIGN KEY (ma_dv) REFERENCES DICH_VU(ma_dv),
    CONSTRAINT CK_CN_DICH_VU_suc_chua   CHECK (suc_chua IS NULL OR suc_chua > 0),
    CONSTRAINT CK_CN_DICH_VU_trang_thai CHECK (trang_thai IN ('HOAT_DONG','TAM_NGUNG'))
);
GO

CREATE TABLE CUA_KIEM_SOAT (
    ma_cua        SMALLINT      IDENTITY(1,1) NOT NULL,
    ma_cn         SMALLINT      NOT NULL,
    vi_tri        NVARCHAR(50)  NOT NULL,
    loai_thiet_bi VARCHAR(15)   NOT NULL,
    trang_thai    VARCHAR(15)   NOT NULL CONSTRAINT DF_CUA_KIEM_SOAT_trang_thai DEFAULT 'HOAT_DONG',
    CONSTRAINT PK_CUA_KIEM_SOAT PRIMARY KEY (ma_cua),
    CONSTRAINT FK_CUA_KIEM_SOAT_CHI_NHANH FOREIGN KEY (ma_cn) REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT UQ_CUA_KIEM_SOAT_cua_cn  UNIQUE (ma_cua, ma_cn),   -- RB11: để CHECK_IN tham chiếu tổ hợp
    CONSTRAINT UQ_CUA_KIEM_SOAT_cn_vitri UNIQUE (ma_cn, vi_tri),  -- RB11
    CONSTRAINT CK_CUA_KIEM_SOAT_loai CHECK (loai_thiet_bi IN ('CONG_QUAY','MAY_QUET_QR')),
    CONSTRAINT CK_CUA_KIEM_SOAT_trang_thai CHECK (trang_thai IN ('HOAT_DONG','BAO_TRI'))
);
GO

CREATE TABLE NHAN_VIEN (
    ma_nv         INT           IDENTITY(1,1) NOT NULL,
    ho_ten        NVARCHAR(100) NOT NULL,
    sdt           VARCHAR(15)   NOT NULL,
    luong_co_ban  DECIMAL(15,0) NOT NULL,
    ngay_vao_lam  DATE          NOT NULL,
    trang_thai    VARCHAR(15)   NOT NULL CONSTRAINT DF_NHAN_VIEN_trang_thai DEFAULT 'DANG_LAM',
    CONSTRAINT PK_NHAN_VIEN PRIMARY KEY (ma_nv),
    CONSTRAINT UQ_NHAN_VIEN_sdt UNIQUE (sdt),                                  -- RB10
    CONSTRAINT CK_NHAN_VIEN_sdt   CHECK (sdt NOT LIKE '%[^0-9]%'),
    CONSTRAINT CK_NHAN_VIEN_luong CHECK (luong_co_ban >= 0),                   -- RB08
    CONSTRAINT CK_NHAN_VIEN_trang_thai CHECK (trang_thai IN ('DANG_LAM','NGHI_VIEC'))
);
GO

CREATE TABLE HUAN_LUYEN_VIEN (
    ma_nv         INT           NOT NULL,
    chuyen_mon    NVARCHAR(100) NOT NULL,
    chung_chi     NVARCHAR(200) NULL,
    ty_le_hoa_hong DECIMAL(5,4) NOT NULL,
    CONSTRAINT PK_HUAN_LUYEN_VIEN PRIMARY KEY (ma_nv),
    CONSTRAINT FK_HLV_NHAN_VIEN FOREIGN KEY (ma_nv) REFERENCES NHAN_VIEN(ma_nv),
    CONSTRAINT CK_HLV_ty_le CHECK (ty_le_hoa_hong BETWEEN 0 AND 1)             -- RB08
);
GO

CREATE TABLE LICH_SU_CONG_TAC (
    ma_ls     INT           IDENTITY(1,1) NOT NULL,
    ma_nv     INT           NOT NULL,
    ma_cn     SMALLINT      NOT NULL,
    chuc_vu   VARCHAR(20)   NOT NULL,
    tu_ngay   DATE          NOT NULL,   -- khoảng nửa mở [tu_ngay, den_ngay)
    den_ngay  DATE          NULL,       -- NULL = đang công tác
    ly_do     NVARCHAR(200) NULL,
    CONSTRAINT PK_LICH_SU_CONG_TAC PRIMARY KEY (ma_ls),
    CONSTRAINT FK_LSCT_NHAN_VIEN FOREIGN KEY (ma_nv) REFERENCES NHAN_VIEN(ma_nv),
    CONSTRAINT FK_LSCT_CHI_NHANH FOREIGN KEY (ma_cn) REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT UQ_LSCT_nv_tungay UNIQUE (ma_nv, tu_ngay),                      -- khóa ứng viên (mục 4.2)
    CONSTRAINT CK_LSCT_chuc_vu CHECK (chuc_vu IN ('PT','LE_TAN','QUAN_LY','NV_BAN_HANG')), -- RB02
    CONSTRAINT CK_LSCT_den_ngay CHECK (den_ngay IS NULL OR den_ngay > tu_ngay)  -- RB16
);
GO
-- RB13: mỗi nhân viên tối đa một giai đoạn công tác đang mở
CREATE UNIQUE INDEX UX_LSCT_nv_dang_mo ON LICH_SU_CONG_TAC (ma_nv) WHERE den_ngay IS NULL;
GO

/* =====================================================================
   PHÂN HỆ B - HỘI VIÊN VÀ THÂN THIẾT
   ===================================================================== */

CREATE TABLE HOI_VIEN (
    ma_hv         INT           IDENTITY(1,1) NOT NULL,
    ma_the        VARCHAR(30)   NOT NULL,
    ho_ten        NVARCHAR(100) NOT NULL,
    sdt           VARCHAR(15)   NOT NULL,
    email         VARCHAR(100)  NULL,
    cccd          CHAR(12)      NOT NULL,
    gioi_tinh     CHAR(1)       NOT NULL,
    ngay_sinh     DATE          NOT NULL,
    ngay_dang_ky  DATE          NOT NULL CONSTRAINT DF_HOI_VIEN_ngay_dk DEFAULT (CAST(SYSDATETIME() AS DATE)),
    trang_thai    VARCHAR(10)   NOT NULL CONSTRAINT DF_HOI_VIEN_trang_thai DEFAULT 'HOAT_DONG',
    CONSTRAINT PK_HOI_VIEN PRIMARY KEY (ma_hv),
    CONSTRAINT UQ_HOI_VIEN_ma_the UNIQUE (ma_the),                             -- RB10
    CONSTRAINT UQ_HOI_VIEN_sdt    UNIQUE (sdt),
    CONSTRAINT UQ_HOI_VIEN_cccd   UNIQUE (cccd),
    CONSTRAINT CK_HOI_VIEN_sdt   CHECK (sdt NOT LIKE '%[^0-9]%'),
    CONSTRAINT CK_HOI_VIEN_cccd  CHECK (cccd NOT LIKE '%[^0-9]%' AND LEN(cccd) = 12), -- RB03
    CONSTRAINT CK_HOI_VIEN_email CHECK (email IS NULL OR email LIKE '_%@_%._%'),      -- RB03
    CONSTRAINT CK_HOI_VIEN_gioi_tinh CHECK (gioi_tinh IN ('M','F','O')),
    CONSTRAINT CK_HOI_VIEN_trang_thai CHECK (trang_thai IN ('HOAT_DONG','KHOA')),
    CONSTRAINT CK_HOI_VIEN_ngay CHECK (ngay_sinh < ngay_dang_ky)               -- RB17
);
GO

CREATE TABLE HANG_THANH_VIEN (
    ma_hang          TINYINT       NOT NULL,   -- 1,2,3 tăng dần
    ten_hang         VARCHAR(10)   NOT NULL,
    nguong_chi_tieu  DECIMAL(15,0) NOT NULL,
    CONSTRAINT PK_HANG_THANH_VIEN PRIMARY KEY (ma_hang),
    CONSTRAINT UQ_HANG_ten_hang UNIQUE (ten_hang),
    CONSTRAINT CK_HANG_nguong CHECK (nguong_chi_tieu >= 0)
    -- RB24 (ngưỡng tăng dần theo ma_hang): kiểm bằng trigger ở Giai đoạn 2 - script 02
);
GO

CREATE TABLE TAI_KHOAN_LOYALTY (
    ma_hv            INT           NOT NULL,
    ma_hang          TINYINT       NOT NULL CONSTRAINT DF_TKL_ma_hang DEFAULT 1,
    diem_hien_co     INT           NOT NULL CONSTRAINT DF_TKL_diem DEFAULT 0,
    tong_chi_tieu_12t DECIMAL(15,0) NOT NULL CONSTRAINT DF_TKL_chitieu DEFAULT 0,
    ngay_xet_hang    DATE          NULL,
    CONSTRAINT PK_TAI_KHOAN_LOYALTY PRIMARY KEY (ma_hv),
    CONSTRAINT FK_TKL_HOI_VIEN FOREIGN KEY (ma_hv) REFERENCES HOI_VIEN(ma_hv) ON DELETE CASCADE,
    CONSTRAINT FK_TKL_HANG     FOREIGN KEY (ma_hang) REFERENCES HANG_THANH_VIEN(ma_hang),
    CONSTRAINT CK_TKL_diem    CHECK (diem_hien_co >= 0),
    CONSTRAINT CK_TKL_chitieu CHECK (tong_chi_tieu_12t >= 0)
);
GO

/* =====================================================================
   PHÂN HỆ C - BÁN HÀNG VÀ THANH TOÁN
   (HOA_DON tạo trước GIAO_DICH_DIEM vì GIAO_DICH_DIEM tham chiếu HOA_DON)
   ===================================================================== */

CREATE TABLE HOA_DON (
    ma_hd      BIGINT        IDENTITY(1,1) NOT NULL,
    ma_hv      INT           NULL,          -- NULL = khách lẻ (BR16, RB41)
    ma_nv_lap  INT           NOT NULL,
    ma_cn      SMALLINT      NOT NULL,
    ngay_lap   DATETIME2(0)  NOT NULL CONSTRAINT DF_HOA_DON_ngay_lap DEFAULT (SYSDATETIME()),
    tong_tien  DECIMAL(15,0) NOT NULL,
    giam_gia   DECIMAL(15,0) NOT NULL CONSTRAINT DF_HOA_DON_giam_gia DEFAULT 0,
    thanh_toan DECIMAL(15,0) NOT NULL,
    trang_thai VARCHAR(15)   NOT NULL CONSTRAINT DF_HOA_DON_trang_thai DEFAULT 'CHO_THANH_TOAN',
    CONSTRAINT PK_HOA_DON PRIMARY KEY (ma_hd),
    CONSTRAINT FK_HOA_DON_HOI_VIEN  FOREIGN KEY (ma_hv)     REFERENCES HOI_VIEN(ma_hv),
    CONSTRAINT FK_HOA_DON_NHAN_VIEN FOREIGN KEY (ma_nv_lap) REFERENCES NHAN_VIEN(ma_nv),
    CONSTRAINT FK_HOA_DON_CHI_NHANH FOREIGN KEY (ma_cn)     REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT CK_HOA_DON_tong     CHECK (tong_tien >= 0),
    CONSTRAINT CK_HOA_DON_giam_gia CHECK (giam_gia >= 0 AND giam_gia <= tong_tien),   -- RB19
    CONSTRAINT CK_HOA_DON_thanh_toan CHECK (thanh_toan = tong_tien - giam_gia),       -- RB19
    CONSTRAINT CK_HOA_DON_trang_thai CHECK (trang_thai IN ('CHO_THANH_TOAN','DA_THANH_TOAN','DA_HUY')) -- RB05
);
GO

CREATE TABLE GIAO_DICH_DIEM (
    ma_gd    BIGINT        IDENTITY(1,1) NOT NULL,
    ma_hv    INT           NOT NULL,
    ma_hd    BIGINT        NULL,            -- NULL khi điều chỉnh thủ công
    loai_gd  VARCHAR(15)   NOT NULL,
    so_diem  INT           NOT NULL,
    ngay_gd  DATETIME2(0)  NOT NULL CONSTRAINT DF_GDD_ngay DEFAULT (SYSDATETIME()),
    ghi_chu  NVARCHAR(200) NULL,
    CONSTRAINT PK_GIAO_DICH_DIEM PRIMARY KEY (ma_gd),
    CONSTRAINT FK_GDD_HOI_VIEN FOREIGN KEY (ma_hv) REFERENCES HOI_VIEN(ma_hv),
    CONSTRAINT FK_GDD_HOA_DON  FOREIGN KEY (ma_hd) REFERENCES HOA_DON(ma_hd),
    CONSTRAINT CK_GDD_loai CHECK (loai_gd IN ('TICH','HOAN_TICH','DIEU_CHINH','DOI_DIEM')), -- RB07
    CONSTRAINT CK_GDD_so_diem CHECK (
        so_diem <> 0 AND                                                           -- RB07
        (loai_gd <> 'TICH'      OR so_diem > 0) AND                                -- RB22
        (loai_gd <> 'HOAN_TICH' OR so_diem < 0) AND
        (loai_gd <> 'DOI_DIEM'  OR so_diem < 0))
);
GO
-- RB14: mỗi hóa đơn tích điểm tối đa một lần
CREATE UNIQUE INDEX UX_GDD_hd_tich ON GIAO_DICH_DIEM (ma_hd) WHERE loai_gd = 'TICH';
GO

CREATE TABLE GOI_DICH_VU (
    ma_goi          SMALLINT      IDENTITY(1,1) NOT NULL,
    ma_dv           SMALLINT      NOT NULL,
    ten_goi         NVARCHAR(100) NOT NULL,
    thoi_han_thang  TINYINT       NULL,      -- 3/6/12; NULL với vé Spa lẻ
    so_buoi_pt      SMALLINT      NULL,      -- bắt buộc khi dịch vụ là PT (RB28 - trigger)
    gia_tien        DECIMAL(15,0) NOT NULL,
    trang_thai_ban  VARCHAR(15)   NOT NULL CONSTRAINT DF_GDV_trang_thai DEFAULT 'DANG_BAN',
    CONSTRAINT PK_GOI_DICH_VU PRIMARY KEY (ma_goi),
    CONSTRAINT FK_GDV_DICH_VU FOREIGN KEY (ma_dv) REFERENCES DICH_VU(ma_dv),
    CONSTRAINT CK_GDV_thoi_han  CHECK (thoi_han_thang IS NULL OR thoi_han_thang IN (3,6,12)), -- RB04
    CONSTRAINT CK_GDV_so_buoi   CHECK (so_buoi_pt IS NULL OR so_buoi_pt > 0),
    CONSTRAINT CK_GDV_gia       CHECK (gia_tien >= 0),
    CONSTRAINT CK_GDV_trang_thai CHECK (trang_thai_ban IN ('DANG_BAN','NGUNG_BAN'))
);
GO

CREATE TABLE GOI_DA_MUA (
    ma_goi_mua    BIGINT        IDENTITY(1,1) NOT NULL,
    ma_hd         BIGINT        NOT NULL,
    ma_goi        SMALLINT      NOT NULL,
    don_gia       DECIMAL(15,0) NOT NULL,   -- giá chốt tại lúc bán
    ngay_bat_dau  DATE          NOT NULL,
    ngay_het_han  DATE          NOT NULL,
    so_buoi_con_lai SMALLINT    NULL,
    trang_thai    VARCHAR(15)   NOT NULL CONSTRAINT DF_GDM_trang_thai DEFAULT 'CHO_KICH_HOAT',
    CONSTRAINT PK_GOI_DA_MUA PRIMARY KEY (ma_goi_mua),
    CONSTRAINT FK_GDM_HOA_DON    FOREIGN KEY (ma_hd)   REFERENCES HOA_DON(ma_hd),
    CONSTRAINT FK_GDM_GOI_DICH_VU FOREIGN KEY (ma_goi) REFERENCES GOI_DICH_VU(ma_goi),
    CONSTRAINT CK_GDM_don_gia CHECK (don_gia >= 0),
    CONSTRAINT CK_GDM_ngay    CHECK (ngay_het_han >= ngay_bat_dau),            -- RB18
    CONSTRAINT CK_GDM_so_buoi CHECK (so_buoi_con_lai IS NULL OR so_buoi_con_lai >= 0),
    CONSTRAINT CK_GDM_trang_thai CHECK (trang_thai IN ('CHO_KICH_HOAT','HIEU_LUC','HET_HAN','DA_HUY')) -- RB05
);
GO

CREATE TABLE LOAI_SAN_PHAM (
    ma_loai  SMALLINT     IDENTITY(1,1) NOT NULL,
    ten_loai NVARCHAR(50) NOT NULL,
    CONSTRAINT PK_LOAI_SAN_PHAM PRIMARY KEY (ma_loai),
    CONSTRAINT UQ_LOAI_SAN_PHAM_ten UNIQUE (ten_loai)
);
GO

CREATE TABLE SAN_PHAM (
    ma_sp       INT           IDENTITY(1,1) NOT NULL,
    ma_loai     SMALLINT      NOT NULL,
    ten_sp      NVARCHAR(100) NOT NULL,
    gia_ban     DECIMAL(15,0) NOT NULL,
    don_vi_tinh NVARCHAR(20)  NOT NULL,
    trang_thai  VARCHAR(15)   NOT NULL CONSTRAINT DF_SAN_PHAM_trang_thai DEFAULT 'DANG_BAN',
    CONSTRAINT PK_SAN_PHAM PRIMARY KEY (ma_sp),
    CONSTRAINT FK_SAN_PHAM_LOAI FOREIGN KEY (ma_loai) REFERENCES LOAI_SAN_PHAM(ma_loai),
    CONSTRAINT CK_SAN_PHAM_gia CHECK (gia_ban >= 0),
    CONSTRAINT CK_SAN_PHAM_trang_thai CHECK (trang_thai IN ('DANG_BAN','NGUNG_BAN'))
);
GO

CREATE TABLE TON_KHO (
    ma_cn            SMALLINT     NOT NULL,
    ma_sp            INT          NOT NULL,
    so_luong_ton     INT          NOT NULL,
    muc_ton_toi_thieu INT         NOT NULL CONSTRAINT DF_TON_KHO_muc DEFAULT 0,
    ngay_cap_nhat    DATETIME2(0) NOT NULL CONSTRAINT DF_TON_KHO_ngay DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_TON_KHO PRIMARY KEY (ma_cn, ma_sp),
    CONSTRAINT FK_TON_KHO_CHI_NHANH FOREIGN KEY (ma_cn) REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT FK_TON_KHO_SAN_PHAM  FOREIGN KEY (ma_sp) REFERENCES SAN_PHAM(ma_sp),
    CONSTRAINT CK_TON_KHO_ton CHECK (so_luong_ton >= 0),                       -- BR10, RB08
    CONSTRAINT CK_TON_KHO_muc CHECK (muc_ton_toi_thieu >= 0)
);
GO

CREATE TABLE CT_HD_SAN_PHAM (
    ma_hd    BIGINT        NOT NULL,
    ma_sp    INT           NOT NULL,
    so_luong INT           NOT NULL,
    don_gia  DECIMAL(15,0) NOT NULL,    -- giá chốt; thành tiền = so_luong * don_gia (không lưu)
    CONSTRAINT PK_CT_HD_SAN_PHAM PRIMARY KEY (ma_hd, ma_sp),
    CONSTRAINT FK_CTHD_HOA_DON  FOREIGN KEY (ma_hd) REFERENCES HOA_DON(ma_hd),
    CONSTRAINT FK_CTHD_SAN_PHAM FOREIGN KEY (ma_sp) REFERENCES SAN_PHAM(ma_sp),
    CONSTRAINT CK_CTHD_so_luong CHECK (so_luong > 0),                          -- RB08
    CONSTRAINT CK_CTHD_don_gia  CHECK (don_gia >= 0)
);
GO

CREATE TABLE THANH_TOAN (
    ma_tt            BIGINT        IDENTITY(1,1) NOT NULL,
    ma_hd            BIGINT        NOT NULL,
    hinh_thuc        VARCHAR(10)   NOT NULL,
    so_tien          DECIMAL(15,0) NOT NULL,
    ma_giao_dich_cong VARCHAR(50)  NULL,
    thoi_diem        DATETIME2(0)  NOT NULL CONSTRAINT DF_THANH_TOAN_thoi_diem DEFAULT (SYSDATETIME()),
    trang_thai       VARCHAR(15)   NOT NULL,
    CONSTRAINT PK_THANH_TOAN PRIMARY KEY (ma_tt),
    CONSTRAINT FK_THANH_TOAN_HOA_DON FOREIGN KEY (ma_hd) REFERENCES HOA_DON(ma_hd),
    CONSTRAINT CK_THANH_TOAN_hinh_thuc CHECK (hinh_thuc IN ('TIEN_MAT','VNPAY','THE')),   -- RB06
    CONSTRAINT CK_THANH_TOAN_so_tien   CHECK (so_tien > 0),
    CONSTRAINT CK_THANH_TOAN_trang_thai CHECK (trang_thai IN ('THANH_CONG','THAT_BAI','HOAN_TIEN')),
    CONSTRAINT CK_THANH_TOAN_ma_gd CHECK (hinh_thuc = 'TIEN_MAT' OR ma_giao_dich_cong IS NOT NULL) -- RB23
);
GO
-- RB14: mã giao dịch cổng không trùng
CREATE UNIQUE INDEX UX_THANH_TOAN_ma_gd ON THANH_TOAN (ma_giao_dich_cong) WHERE ma_giao_dich_cong IS NOT NULL;
GO

/* =====================================================================
   PHÂN HỆ D - VẬN HÀNH: CHECK-IN VÀ LỊCH PT
   ===================================================================== */

CREATE TABLE KHUNG_GIO (
    ma_khung_gio TINYINT NOT NULL,        -- 1..17
    gio_bat_dau  TIME(0) NOT NULL,        -- 05:00 .. 21:00
    gio_ket_thuc TIME(0) NOT NULL,        -- = gio_bat_dau + 60 phút
    CONSTRAINT PK_KHUNG_GIO PRIMARY KEY (ma_khung_gio),
    CONSTRAINT UQ_KHUNG_GIO_bat_dau UNIQUE (gio_bat_dau),
    CONSTRAINT CK_KHUNG_GIO_ket_thuc CHECK (gio_ket_thuc = DATEADD(MINUTE, 60, gio_bat_dau))
);
GO

/* CHECK_IN: bảng log lớn nhất (~3,6 triệu dòng/năm).
   - Khóa cụm (tg_vao, ma_checkin): chèn cuối bảng, partition key nằm trong khóa cụm.
   - ma_cn nhắc lại có chủ đích; FK tổ hợp (ma_cua, ma_cn) bảo đảm khớp chi nhánh của cửa.
   - Express: đổi "ON ps_checkin_thang(tg_vao)" thành "ON [PRIMARY]". */
CREATE TABLE CHECK_IN (
    ma_checkin  BIGINT       IDENTITY(1,1) NOT NULL,
    ma_hv       INT          NOT NULL,
    ma_cua      SMALLINT     NOT NULL,
    ma_cn       SMALLINT     NOT NULL,
    ma_goi_mua  BIGINT       NULL,         -- NULL khi bị từ chối
    tg_vao      DATETIME2(0) NOT NULL,
    tg_ra       DATETIME2(0) NULL,
    ket_qua     VARCHAR(10)  NOT NULL,
    CONSTRAINT PK_CHECK_IN PRIMARY KEY CLUSTERED (tg_vao, ma_checkin),
    CONSTRAINT FK_CHECK_IN_HOI_VIEN FOREIGN KEY (ma_hv) REFERENCES HOI_VIEN(ma_hv),
    CONSTRAINT FK_CHECK_IN_CUA FOREIGN KEY (ma_cua, ma_cn) REFERENCES CUA_KIEM_SOAT(ma_cua, ma_cn),
    CONSTRAINT FK_CHECK_IN_GOI_DA_MUA FOREIGN KEY (ma_goi_mua) REFERENCES GOI_DA_MUA(ma_goi_mua),
    CONSTRAINT CK_CHECK_IN_tg_ra CHECK (tg_ra IS NULL OR tg_ra >= tg_vao),     -- RB20
    CONSTRAINT CK_CHECK_IN_ket_qua CHECK (                                     -- RB09, RB20
        (ket_qua = 'HOP_LE'   AND ma_goi_mua IS NOT NULL) OR
        (ket_qua = 'TU_CHOI'  AND ma_goi_mua IS NULL))
) ON ps_checkin_thang(tg_vao);
GO

CREATE TABLE LICH_HEN_PT (
    ma_lich       BIGINT        IDENTITY(1,1) NOT NULL,
    ma_hv         INT           NOT NULL,
    ma_hlv        INT           NOT NULL,
    ma_cn         SMALLINT      NOT NULL,
    ma_goi_mua    BIGINT        NOT NULL,
    ngay_tap      DATE          NOT NULL,
    ma_khung_gio  TINYINT       NOT NULL,
    trang_thai    VARCHAR(15)   NOT NULL CONSTRAINT DF_LHPT_trang_thai DEFAULT 'DA_DAT',
    ngay_dat      DATETIME2(0)  NOT NULL CONSTRAINT DF_LHPT_ngay_dat DEFAULT (SYSDATETIME()),
    ly_do_huy     NVARCHAR(200) NULL,
    diem_danh_gia TINYINT       NULL,
    nhan_xet      NVARCHAR(300) NULL,
    CONSTRAINT PK_LICH_HEN_PT PRIMARY KEY (ma_lich),
    CONSTRAINT FK_LHPT_HOI_VIEN  FOREIGN KEY (ma_hv)  REFERENCES HOI_VIEN(ma_hv),
    CONSTRAINT FK_LHPT_HLV       FOREIGN KEY (ma_hlv) REFERENCES HUAN_LUYEN_VIEN(ma_nv),
    CONSTRAINT FK_LHPT_CHI_NHANH FOREIGN KEY (ma_cn)  REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT FK_LHPT_GOI_DA_MUA FOREIGN KEY (ma_goi_mua) REFERENCES GOI_DA_MUA(ma_goi_mua),
    CONSTRAINT FK_LHPT_KHUNG_GIO FOREIGN KEY (ma_khung_gio) REFERENCES KHUNG_GIO(ma_khung_gio),
    CONSTRAINT CK_LHPT_trang_thai CHECK (trang_thai IN ('DA_DAT','DA_HOAN_THANH','DA_HUY')),      -- RB09
    CONSTRAINT CK_LHPT_diem CHECK (diem_danh_gia IS NULL OR diem_danh_gia BETWEEN 1 AND 5),       -- RB09
    CONSTRAINT CK_LHPT_ly_do_huy CHECK (                                                           -- RB21
        (trang_thai = 'DA_HUY'  AND ly_do_huy IS NOT NULL) OR
        (trang_thai <> 'DA_HUY' AND ly_do_huy IS NULL)),
    CONSTRAINT CK_LHPT_danh_gia CHECK (diem_danh_gia IS NULL OR trang_thai = 'DA_HOAN_THANH'),    -- RB21 / BR08
    CONSTRAINT CK_LHPT_ngay_dat CHECK (CAST(ngay_dat AS DATE) <= ngay_tap)
);
GO
-- RB12 (vấn đề 2): chặn tuyệt đối overbooking - UNIQUE có lọc
CREATE UNIQUE INDEX UX_LHPT_hlv_khung ON LICH_HEN_PT (ma_hlv, ngay_tap, ma_khung_gio) WHERE trang_thai <> 'DA_HUY';
CREATE UNIQUE INDEX UX_LHPT_hv_khung  ON LICH_HEN_PT (ma_hv,  ngay_tap, ma_khung_gio) WHERE trang_thai <> 'DA_HUY';
GO

/* =====================================================================
   BẢNG DẪN XUẤT (Phần 2, mục 5.6) - tính lại được từ 22 bảng lõi
   ===================================================================== */

-- Vấn đề 1: quyền vào cổng, 1 dòng / (hội viên, dịch vụ)
CREATE TABLE QUYEN_VAO_CONG (
    ma_hv           INT          NOT NULL,
    ma_dv           SMALLINT     NOT NULL,
    ngay_het_han    DATE         NOT NULL,
    ma_goi_mua      BIGINT       NOT NULL,
    so_luot_con_lai SMALLINT     NULL,
    cap_nhat_luc    DATETIME2(0) NOT NULL CONSTRAINT DF_QVC_cap_nhat DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_QUYEN_VAO_CONG PRIMARY KEY (ma_hv, ma_dv),
    CONSTRAINT FK_QVC_HOI_VIEN  FOREIGN KEY (ma_hv) REFERENCES HOI_VIEN(ma_hv),
    CONSTRAINT FK_QVC_DICH_VU   FOREIGN KEY (ma_dv) REFERENCES DICH_VU(ma_dv),
    CONSTRAINT FK_QVC_GOI_DA_MUA FOREIGN KEY (ma_goi_mua) REFERENCES GOI_DA_MUA(ma_goi_mua),
    CONSTRAINT CK_QVC_luot CHECK (so_luot_con_lai IS NULL OR so_luot_con_lai >= 0)
);
GO

-- Vấn đề 3: tổng hợp doanh thu / lấp đầy
CREATE TABLE TH_DOANH_THU_NGAY (
    ma_cn              SMALLINT      NOT NULL,
    ngay               DATE          NOT NULL,
    so_hoa_don         INT           NOT NULL CONSTRAINT DF_THDTN_sohd DEFAULT 0,
    doanh_thu_goi      DECIMAL(15,0) NOT NULL CONSTRAINT DF_THDTN_goi  DEFAULT 0,
    doanh_thu_san_pham DECIMAL(15,0) NOT NULL CONSTRAINT DF_THDTN_sp   DEFAULT 0,
    CONSTRAINT PK_TH_DOANH_THU_NGAY PRIMARY KEY (ma_cn, ngay),
    CONSTRAINT FK_THDTN_CHI_NHANH FOREIGN KEY (ma_cn) REFERENCES CHI_NHANH(ma_cn)
);
GO

CREATE TABLE TH_DOANH_THU_GOI_THANG (
    ma_goi       SMALLINT      NOT NULL,
    thang        DATE          NOT NULL,   -- ngày đầu tháng
    so_luong_ban INT           NOT NULL CONSTRAINT DF_THDTG_sl DEFAULT 0,
    doanh_thu    DECIMAL(15,0) NOT NULL CONSTRAINT DF_THDTG_dt DEFAULT 0,
    CONSTRAINT PK_TH_DOANH_THU_GOI_THANG PRIMARY KEY (ma_goi, thang),
    CONSTRAINT FK_THDTG_GOI FOREIGN KEY (ma_goi) REFERENCES GOI_DICH_VU(ma_goi),
    CONSTRAINT CK_THDTG_thang CHECK (DAY(thang) = 1)
);
GO

CREATE TABLE TH_LAP_DAY_GIO (
    ma_cn           SMALLINT NOT NULL,
    ngay            DATE     NOT NULL,
    gio             TINYINT  NOT NULL,     -- 0..23
    so_luot_vao     INT      NOT NULL CONSTRAINT DF_THLDG_luot DEFAULT 0,
    so_nguoi_co_mat INT      NOT NULL CONSTRAINT DF_THLDG_comat DEFAULT 0,
    CONSTRAINT PK_TH_LAP_DAY_GIO PRIMARY KEY (ma_cn, ngay, gio),
    CONSTRAINT FK_THLDG_CHI_NHANH FOREIGN KEY (ma_cn) REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT CK_THLDG_gio CHECK (gio BETWEEN 0 AND 23)
);
GO

-- Vấn đề 4: chi tiêu theo tháng của hội viên (cửa sổ 12 tháng)
CREATE TABLE CHI_TIEU_THANG_HV (
    ma_hv         INT           NOT NULL,
    thang         DATE          NOT NULL,   -- ngày đầu tháng
    tong_chi_tieu DECIMAL(15,0) NOT NULL CONSTRAINT DF_CTTH_tong DEFAULT 0,
    CONSTRAINT PK_CHI_TIEU_THANG_HV PRIMARY KEY (ma_hv, thang),
    CONSTRAINT FK_CTTH_HOI_VIEN FOREIGN KEY (ma_hv) REFERENCES HOI_VIEN(ma_hv),
    CONSTRAINT CK_CTTH_thang CHECK (DAY(thang) = 1)
);
GO

-- Vấn đề 5: hoa hồng PT chốt theo tháng và chi nhánh
CREATE TABLE HOA_HONG_HLV_THANG (
    ma_hlv            INT           NOT NULL,
    ma_cn             SMALLINT      NOT NULL,
    thang             DATE          NOT NULL,   -- ngày đầu tháng
    so_buoi_hoan_thanh INT          NOT NULL CONSTRAINT DF_HHHT_buoi DEFAULT 0,
    tong_hoa_hong     DECIMAL(15,0) NOT NULL CONSTRAINT DF_HHHT_tong DEFAULT 0,
    ngay_chot         DATETIME2(0)  NULL,       -- NULL = chưa chốt
    CONSTRAINT PK_HOA_HONG_HLV_THANG PRIMARY KEY (ma_hlv, ma_cn, thang),
    CONSTRAINT FK_HHHT_HLV       FOREIGN KEY (ma_hlv) REFERENCES HUAN_LUYEN_VIEN(ma_nv),
    CONSTRAINT FK_HHHT_CHI_NHANH FOREIGN KEY (ma_cn)  REFERENCES CHI_NHANH(ma_cn),
    CONSTRAINT CK_HHHT_thang CHECK (DAY(thang) = 1)
);
GO

/* =====================================================================
   DỮ LIỆU DANH MỤC CỐ ĐỊNH (seed)
   ===================================================================== */

-- Dịch vụ (mục 2.5 Phần 1)
INSERT INTO DICH_VU (ten_dv, nhom_dv, mo_ta) VALUES
 (N'Gym',      'PHONG_TAP', N'Phòng tập thiết bị'),
 (N'Yoga',     'PHONG_TAP', N'Lớp Yoga'),
 (N'GroupX',   'PHONG_TAP', N'Lớp nhóm GroupX'),
 (N'PT 1-1',   'PT',        N'Huấn luyện viên cá nhân'),
 (N'Spa',      'SPA_SAUNA', N'Dịch vụ Spa'),
 (N'Sauna',    'SPA_SAUNA', N'Phòng xông hơi'),
 (N'Cửa hàng', 'CUA_HANG',  N'Cửa hàng thực phẩm bổ sung/phụ kiện');
GO

-- Hạng thành viên (ngưỡng chi tiêu 12 tháng theo chính sách của nhóm)
INSERT INTO HANG_THANH_VIEN (ma_hang, ten_hang, nguong_chi_tieu) VALUES
 (1, 'SILVER',   0),
 (2, 'GOLD',     20000000),
 (3, 'PLATINUM', 50000000);
GO

-- 17 khung giờ PT, mỗi khung 60 phút: 05:00-06:00 ... 21:00-22:00
;WITH n AS (SELECT TOP (17) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
INSERT INTO KHUNG_GIO (ma_khung_gio, gio_bat_dau, gio_ket_thuc)
SELECT i,
       DATEADD(HOUR, 4 + i, CAST('00:00' AS TIME(0))),
       DATEADD(HOUR, 5 + i, CAST('00:00' AS TIME(0)))
FROM n;
GO

/* Kiểm tra nhanh sau khi chạy */
SELECT t.name AS bang, SUM(p.rows) AS so_dong
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY t.name
ORDER BY t.name;
GO
