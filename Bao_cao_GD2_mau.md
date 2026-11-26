# BÁO CÁO GIAI ĐOẠN 2 – THIẾT KẾ VẬT LÝ & ỨNG DỤNG
**Môn:** CSC12002 – Cơ sở dữ liệu nâng cao · **Mã đồ án:** 2627.ADB.01 · **Đề tài:** FitLife Hub
**Nhóm:** 2627.ADB.CLC14 · **GV thực hành:** Hồ Thị Hoàng Vy, Tiết Gia Hồng

## 1. Thông tin nhóm
| MSSV | Họ tên | Vai trò | Phần việc chính | Tự đánh giá (%) |
|---|---|---|---|---|
| 22127403 | Nguyễn Trần Minh Thư | Nhóm trưởng | Kịch bản 1, 2 + tích hợp, báo cáo | |
| 21126050 | Nguyễn Hoàng Anh | | Kịch bản 3, 4 | |
| 21126057 | Nguyễn Hoàng Danh | | Kịch bản 5, 6 | |
| 19127484 | Ngô Trung Nghĩa | | Kịch bản 7, 8, 9 + ứng dụng | |

(Phân công gợi ý – chỉnh lại theo thực tế. Mỗi người tự viết phần đánh giá cá nhân ở mục 7.)

## 2. Môi trường & cách chạy
- SQL Server (phiên bản ____, edition ____), máy: CPU ____, RAM ____, SSD/HDD ____.
- Thứ tự chạy: `01_create_schema.sql` → `02_generate_data.py` → `03_procedures_triggers.sql` → `04_scenarios.sql` → `05_test_concurrency.py` → `app.py`.
- Quy mô dữ liệu sau khi sinh (điền từ `SELECT COUNT(*)`): CHECK_IN ____, HOA_DON ____, GOI_DA_MUA ____, LICH_HEN_PT ____, HOI_VIEN ____ (mỗi bảng minh họa ≥ 70.000 dòng).

## 3. Thiết kế vật lý
3.1 Sơ đồ cơ sở dữ liệu (dán ảnh diagram từ SSMS).
3.2 Danh sách ràng buộc đã cài (bảng RB → cách cài: CHECK/UNIQUE trong 01, trigger/proc trong 03).
3.3 Chỉ mục, phân vùng (CHECK_IN theo tháng, `ps_checkin_thang`), bảng dẫn xuất, trigger, hàm, thủ tục (liệt kê + mục đích).

## 4. Kịch bản (lặp lại cấu trúc dưới đây cho từng kịch bản S1–S9)
Mỗi kịch bản gồm:
1. **Mô tả & vấn đề** (gắn với vấn đề 1–5 của đề).
2. **Tần suất** (vd: S1 > 10.000 lượt/giờ giờ cao điểm).
3. **Truy vấn/thủ tục trước tối ưu** (chép từ `04_scenarios.sql`).
4. **Giải pháp** (chỉ mục / bảng dẫn xuất / phân vùng / trigger) và **lý do chọn**.
5. **Truy vấn sau tối ưu**.
6. **Bảng so sánh** (số liệu từ `SET STATISTICS IO, TIME ON`; không bịa số, chạy thật):

| Chỉ số | Trước | Sau | Cải thiện |
|---|---|---|---|
| Thời gian CPU / elapsed (ms) | | | |
| Logical reads | | | |
| Kế hoạch thực thi (toán tử chính) | | | |

7. **Ảnh chụp** execution plan trước/sau + kết quả STATISTICS.
8. **Nhận xét** (đánh đổi: chi phí ghi, dung lượng; khi nào giải pháp không hiệu quả).

| KB | Nội dung | Vấn đề | Script |
|---|---|---|---|
| S1 | Check-in giờ cao điểm | 1 | 04 (S1), 05 `checkin` |
| S2 | Chống đặt trùng lịch PT | 2 | 04 (S2), 05 `overbook` |
| S3 | Báo cáo doanh thu | 3 | 04 (S3) |
| S4 | Báo cáo lấp đầy theo giờ | 3 | 04 (S4) |
| S5 | Phân vùng và lưu trữ log | 3 | 04 (S5) |
| S6 | Tái tính hạng/điểm | 4 | 04 (S6) |
| S7 | Hoa hồng PT và điều chuyển | 5 | 04 (S7) |
| S8 | Tra cứu hội viên | – | 04 (S8) |
| S9 | Danh sách check-in theo giờ + chi phí ghi | 1, 3 | 04 (S9) |

Lưu ý khi viết S5: truy vấn khoảng thời gian trên khóa cụm `tg_vao` đã seek tốt cả khi không phân vùng; lợi ích chính của phân vùng là **SWITCH/xóa log cũ gần như tức thì** (so sánh với DELETE), nên trình bày đúng như vậy.
Lưu ý S2: ghi rõ số bản ghi trùng ở chế độ `naive` so với 0 ở chế độ `safe`.

## 5. Ứng dụng
Mô tả chức năng (tra cứu, thêm/sửa/khóa hội viên, check-in, đặt/hủy/hoàn thành lịch PT, lập hóa đơn và thanh toán, điều chuyển nhân viên, thống kê có biểu đồ), ảnh chụp từng màn hình, ánh xạ màn hình → thủ tục.

## 6. Công cụ quản lý công việc
Dán ảnh bảng công việc (Trello/GitHub Projects/Notion…): công việc, người phụ trách, hạn, trạng thái.

## 7. Đánh giá
7.1 Đánh giá cá nhân (mỗi thành viên: việc đã làm, khó khăn, bài học).
7.2 Đánh giá chung của nhóm và tỷ lệ đóng góp (tổng 100%).
7.3 Hạn chế và hướng phát triển.

## 8. Tài liệu tham khảo
Tài liệu thực hành của cô Hồ Thị Hoàng Vy; tài liệu SQL Server (Microsoft Learn: partitioning, filtered indexes, execution plans); bài giảng lý thuyết của cô Vũ Thị Mỹ Hằng.
