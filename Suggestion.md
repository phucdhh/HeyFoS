# Đề xuất Nâng cấp Kiến trúc và Thuật toán cho HeyFoS

Tài liệu này tổng hợp các hướng dẫn và đề xuất nhằm nâng cao chất lượng quang học, tối ưu hóa hiệu suất phần cứng và cải thiện kiến trúc mã nguồn cho ứng dụng Focus Stacking - HeyFoS.

## 1. Nâng cấp Lõi Thuật toán Xử lý Ảnh (Core Image Processing)

*   **Tối ưu hóa Khử sai lệch (Alignment & Focus Breathing):**
    *   *Vấn đề:* Khi thay đổi tiêu cự trong chụp ảnh macro, ống kính thường bị hiện tượng "thở" (thay đổi độ phóng đại) và xê dịch vi mô.
    *   *Đề xuất:* Trước bước Pyramid Blending, cần bổ sung một module Alignment sử dụng thuật toán ECC (Enhanced Correlation Coefficient) hoặc tính toán ma trận Homography dựa trên các điểm đặc trưng (Feature Matching như ORB/SIFT). Việc căn chỉnh không chỉ xoay/dịch chuyển mà phải bao gồm cả tỷ lệ (scale) để các lớp ảnh khớp nhau ở mức sub-pixel.
*   **Tinh chỉnh Pyramid Blending:**
    *   Thay thế số lượng mức phân giải (levels) cố định bằng thuật toán tính toán động dựa trên kích thước ảnh đầu vào. Mức base của pyramid nên đạt kích thước rất nhỏ (ví dụ: $16 \times 16$ pixel) để xử lý triệt để quầng sáng (halos) ở các cấu trúc lớn.
    *   Áp dụng hàm lũy thừa (Exponentiation) cho Weight Map trước khi chuẩn hóa để tăng cường độ tương phản và giữ được độ sắc nét tối đa tại vùng ranh giới lấy nét.
*   **Xử lý viền (Edge Padding):** 
    *   Chuyển đổi các hàm tự viết sang sử dụng thư viện `MetalPerformanceShaders` (MPS) của Apple cho các thao tác mờ hóa (Blur) và lấy mẫu (Downsample/Upsample). MPS tự động xử lý tốt hiện tượng viền đen ở các điểm ảnh sát mép.

## 2. Tối ưu Hiệu suất và Quản lý Bộ nhớ (Performance & Memory)

*   **Xử lý luồng dữ liệu theo lô (Chunking/Streaming):**
    *   *Vấn đề:* Việc tải toàn bộ một tệp ảnh lớn (đặc biệt là định dạng TIFF không nén thường dùng trong macro) vào RAM hoặc VRAM của GPU cùng một lúc sẽ gây ra hiện tượng tràn bộ nhớ và crash ứng dụng khi số lượng ảnh đầu vào lớn.
    *   *Đề xuất:* Triển khai cơ chế xử lý phân mảnh (Tile-based processing). Cắt ảnh thành các lưới nhỏ hơn (ví dụ: $1024 \times 1024$), đẩy từng tile qua Metal pipeline để xử lý Focus Stacking, sau đó ghép lại.
*   **Tận dụng Zero-Copy bằng `IOSurface`:**
    *   Đảm bảo quy trình luân chuyển dữ liệu từ không gian bộ nhớ của CPU (Swift) sang GPU (Metal) sử dụng `IOSurface` hoặc `MTLBuffer` dùng chung bộ nhớ để tránh việc sao chép dữ liệu dư thừa.

## 3. Kiến trúc Dự án và Hợp tác Phát triển (Project Architecture)

*   **Tách biệt (Decoupling) UI và Logic lõi:**
    *   Áp dụng mô hình MVVM hoặc Clean Architecture một cách triệt để. Tách biệt hoàn toàn phần giao diện người dùng ra khỏi `HeyFoSCore`.
    *   Điều này giúp mã nguồn dễ đọc hơn, dễ viết Unit Test và đặc biệt thuận lợi khi có nhiều kỹ sư cùng tham gia phát triển và bảo trì hệ thống.
*   **Phát triển giao diện Dòng lệnh (CLI):**
    *   Bên cạnh giao diện đồ họa, nên đóng gói một phiên bản Command Line Interface. Điều này cực kỳ hữu ích để tích hợp HeyFoS vào các pipeline tự động hóa hoặc gọi từ các shell script xử lý hàng loạt.

## 4. Trải nghiệm Người dùng (UX)

*   **Phản hồi tiến độ (Progress Reporting & Cancellation):**
    *   Quá trình xử lý hàng chục tấm ảnh độ phân giải cao tốn nhiều thời gian. Cần xây dựng cơ chế báo cáo tiến độ (progress bar) chi tiết cho từng giai đoạn (Đọc ảnh -> Căn chỉnh -> Tạo Weight Map -> Blending -> Xuất file) và cho phép người dùng hủy (cancel) tiến trình an toàn mà không làm treo ứng dụng.