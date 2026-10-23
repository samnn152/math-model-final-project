# Nhận xét nhanh Step 6

- Đủ 200 lượt, 20 instance × 10 seed; kiểm tra lại độc lập cả 200 nghiệm đều khớp tải ECMP, MLU và MaxSeg.
- 180/200 lượt đạt gap MLU ≤10%, tương ứng 18/20 instance đạt trong toàn bộ 10 lượt.
- SetA-03: gap 32,84% gần như không đổi giữa các seed. SetA-19: gap 20,06% ±5,82 điểm phần trăm; là bộ nhạy seed nhất về MLU (CV 7,41%).
- 200/200 vẫn là Not Optimal với toàn mục tiêu từ điển. 110 lượt có prefix ≥1, nhưng prefix cao nhất chỉ 5; không được đổi nhãn thành Optimal vì gap MLU nhỏ.
- Thời gian optimize! trung bình 1715,65 s; 119 lượt bị SEARCH_WALL_LIMIT trước khi dùng đủ 1800 s optimize!. Cần ghi rõ giới hạn này trong report.
- RAM đỉnh cao nhất 2,813 GiB; không lượt Step 6 nào lỗi guard RAM 6 GiB.
- Dịch vụ bị đánh dấu failed do bước tổng hợp CSV đọc nhầm event JSON, không phải do 200 nghiệm bị lỗi. Bảng sạch đã dựng lại từ đúng 200 JSON chính.

Bảng và biểu đồ đầy đủ: STEP6_ANALYSIS.md, STEP6_TABLE.md, summary_by_instance.csv và charts/.
