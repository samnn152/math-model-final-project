# Nhận xét nhanh Step 6

- Đủ 200 lượt, 20 instance × 10 seed; kiểm tra lại độc lập cả 200 nghiệm đều khớp tải ECMP, MLU và MaxSeg.
- 180/200 lượt đạt gap MLU ≤10%, tương ứng 18/20 instance đạt trong toàn bộ 10 lượt.
- SetA-03: gap 32,84% gần như không đổi giữa các seed. SetA-19: gap 20,06% ±5,82 điểm phần trăm; là bộ nhạy seed nhất về MLU (CV 7,41%).
- 200/200 vẫn là Not Optimal với toàn mục tiêu từ điển. 110 lượt có prefix ≥1, nhưng prefix cao nhất chỉ 5; không được đổi nhãn thành Optimal vì gap MLU nhỏ.
- Thời gian optimize! trung bình 1715,65 s; 119 lượt bị SEARCH_WALL_LIMIT trước khi dùng đủ 1800 s optimize!. Cần ghi rõ giới hạn này trong report.
- RAM đỉnh cao nhất 2,813 GiB; không lượt Step 6 nào lỗi guard RAM 6 GiB.
- Dịch vụ bị đánh dấu failed do bước tổng hợp CSV đọc nhầm event JSON, không phải do 200 nghiệm bị lỗi. Bảng sạch đã dựng lại từ đúng 200 JSON chính.

Bảng và biểu đồ đầy đủ: STEP6_ANALYSIS.md, STEP6_TABLE.md, summary_by_instance.csv và charts/.


## Kiểm tra seed và variance bằng 0

Đã đối chiếu đủ 200 lượt: seed trong kết quả và supervisor đều bằng `1000 + run`; cấu hình và lệnh khởi chạy cũng khớp seed base và số lượt. Mỗi instance dùng seed 1001–1010. Không chạy lại solver khi thực hiện kiểm tra này.

Variance MLU bằng 0 chỉ có nghĩa tải cung lớn nhất giống nhau, không có nghĩa toàn bộ route hay vector tải giống nhau. SetA-01 và SetA-20 đều có 10 bộ route và 10 vector tải khác nhau nhưng chỉ một giá trị MLU. SetA-02 tìm lại cùng bộ route ở cả 10 lượt, trong khi thời gian, số node và file trace khác nhau. Bằng chứng này hỗ trợ các lượt chạy riêng biệt; đây không phải phép đọc lại trạng thái RNG bên trong solver lịch sử.

[Bảng đủ 20 instance và quy tắc đếm](SEED_VARIANCE_AUDIT.md). “Số nghiệm route” đếm bộ waypoint của toàn bộ demand, đã chuẩn hóa thứ tự demand; không đếm riêng từng đường vật lý ECMP. Vector tải được so sánh toàn bộ, không làm tròn. Các sai khác cỡ 1e-17 vẫn được giữ trong phép đếm chính xác nhưng không có ý nghĩa thực tiễn về chất lượng nghiệm.
