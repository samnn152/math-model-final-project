# Kết quả cloud cuối — Step 6 và Step 9

Đã thu đủ **400/400 run**: 20 instance × 10 lần lặp × 2 bước. Đây là batch cũ; không gồm Step 6 v2 hay các pilot sửa chứng nhận local. Không chạy lại solver khi tổng hợp.

| Bước | Run có kết quả | Nhất quán qua kiểm tra bản ghi | Gap MLU ≤10% | Optimal toàn bộ từ điển |
|---|---:|---:|---:|---:|
| Step 6 | 200 | 200 | 180 | 0 |
| Step 9 | 200 | 200 | 170 | 0 |

`completed` nghĩa là tiến trình kết thúc và lưu kết quả. `TIME_LIMIT` và `SEARCH_WALL_LIMIT` không phải chứng nhận Optimal. MLU là tọa độ đầu tiên; gap MLU bằng 0 không chứng minh tối ưu toàn bộ vector.

## Bảng theo instance

± là độ lệch chuẩn mẫu (n−1). Gap là trung bình gap từng run, hiển thị %. Không gộp trung bình MLU giữa các instance. Thời gian optimize là tổng thời lượng optimize! đã ghi, không phải thời gian CPU hệ điều hành.

### Step 6

| Instance | n | MLU trung bình ± SD | LB TB | Gap TB % | Đạt ≤10% | Optimize TB (s) | Wall tiến trình TB (s) | Prefix min–max / tổng |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| setA-01 | 10 | 0.9293839 ± 0 | 0.929383861 | 4.15196e-06 | 10/10 | 1743.8 | 2074.5 | 1–1/80 |
| setA-02 | 10 | 0.548578044 ± 0 | 0.548578013 | 5.64579e-06 | 10/10 | 1550.0 | 2073.5 | 4–4/150 |
| setA-03 | 10 | 0.943543415 ± 0 | 0.633661123 | 32.8424 | 0/10 | 1579.3 | 2074.3 | 0–0/250 |
| setA-04 | 10 | 0.459119347 ± 0 | 0.459119201 | 3.17808e-05 | 10/10 | 1800.1 | 2003.3 | 0–0/250 |
| setA-05 | 10 | 0.115523745 ± 0 | 0.115523745 | 0 | 10/10 | 1580.0 | 2080.4 | 2–2/396 |
| setA-06 | 10 | 0.09859156 ± 1.09e-17 | 0.09859155 | 1.01429e-05 | 10/10 | 1610.2 | 2089.8 | 1–1/500 |
| setA-07 | 10 | 0.907989441 ± 0 | 0.907989403 | 4.20267e-06 | 10/10 | 1692.1 | 2099.9 | 4–4/500 |
| setA-08 | 10 | 0.318903697 ± 0 | 0.318903697 | 2.22045e-14 | 10/10 | 1616.7 | 2078.6 | 1–1/654 |
| setA-09 | 10 | 0.505384211 ± 0 | 0.50538418 | 5.95739e-06 | 10/10 | 1688.4 | 2095.1 | 1–1/750 |
| setA-10 | 10 | 0.069565245 ± 8.5e-09 | 0.069565126 | 0.000171 | 10/10 | 1800.2 | 1976.5 | 0–0/966 |
| setA-11 | 10 | 0.613543841 ± 0 | 0.613543679 | 2.62988e-05 | 10/10 | 1800.5 | 2036.2 | 0–0/1000 |
| setA-12 | 10 | 0.64007503 ± 0 | 0.640074866 | 2.56232e-05 | 10/10 | 1502.8 | 2100.6 | 0–0/898 |
| setA-13 | 10 | 0.03888885 ± 1.23e-17 | 0.0388887461 | 0.000267143 | 10/10 | 1800.7 | 2029.8 | 0–0/1000 |
| setA-14 | 10 | 0.423969311 ± 1.34e-06 | 0.423967616 | 0.000399661 | 10/10 | 1800.1 | 2049.3 | 0–0/1108 |
| setA-15 | 10 | 0.825206 ± 0 | 0.825206 | 1.11022e-14 | 10/10 | 1774.1 | 2106.1 | 3–3/1250 |
| setA-16 | 10 | 0.039682387 ± 0.000876 | 0.0389342659 | 1.84347 | 10/10 | 1803.5 | 2073.8 | 0–0/1452 |
| setA-17 | 10 | 0.424192341 ± 0 | 0.424192341 | 0 | 10/10 | 1790.6 | 2150.7 | 5–5/1270 |
| setA-18 | 10 | 0.633365497 ± 0 | 0.633365497 | 0 | 10/10 | 1797.8 | 2094.6 | 4–4/1500 |
| setA-19 | 10 | 0.058875873 ± 0.00436 | 0.0468383933 | 20.0585 | 0/10 | 1801.7 | 2126.3 | 0–0/1998 |
| setA-20 | 10 | 0.991312385 ± 0 | 0.991312345 | 4.01753e-06 | 10/10 | 1780.4 | 2184.7 | 2–2/2000 |

Trạng thái dừng: {'SEARCH_WALL_LIMIT': 119, 'TIME_LIMIT': 81}.

### Step 9

| Instance | n | MLU trung bình ± SD | LB TB | Gap TB % | Đạt ≤10% | Optimize TB (s) | Wall tiến trình TB (s) | Prefix min–max / tổng |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| setA-01 | 10 | 0.9293839 ± 0 | 0.929383857 | 4.57476e-06 | 10/10 | 3600.0 | 4085.9 | 1–1/160 |
| setA-02 | 10 | 0.903074709 ± 0 | 0.624267428 | 30.8731 | 0/10 | 3600.0 | 4935.6 | 0–0/300 |
| setA-03 | 10 | 0.943543415 ± 0 | 0.63366112 | 32.8424 | 0/10 | 3119.9 | 7496.9 | 0–0/500 |
| setA-04 | 10 | 0.581237186 ± 0 | 0.581237028 | 2.72047e-05 | 10/10 | 3523.8 | 4928.0 | 2–2/500 |
| setA-05 | 10 | 0.204985875 ± 0 | 0.204985875 | 0 | 10/10 | 550.2 | 7590.1 | 1–1/792 |
| setA-06 | 10 | 0.1267606 ± 0 | 0.09859155 | 22.2222 | 0/10 | 391.9 | 7626.5 | 0–0/1000 |
| setA-07 | 10 | 0.907989441 ± 0 | 0.907989383 | 6.3952e-06 | 10/10 | 480.4 | 7611.7 | 1–1/1000 |
| setA-08 | 10 | 0.318903697 ± 0 | 0.318903697 | 2.22045e-14 | 10/10 | 112.4 | 7738.8 | 1–1/1308 |
| setA-09 | 10 | 0.84965 ± 0 | 0.849649958 | 4.92469e-06 | 10/10 | 824.0 | 7388.3 | 3–3/1500 |
| setA-10 | 10 | 0.071739161 ± 3.16e-09 | 0.069565126 | 3.03047 | 10/10 | 3460.5 | 7424.8 | 0–0/1932 |
| setA-11 | 10 | 0.785788957 ± 0 | 0.785788957 | 1.11022e-14 | 10/10 | 539.4 | 7906.7 | 1–1/2000 |
| setA-12 | 10 | 0.879872592 ± 0 | 0.879872592 | 0 | 10/10 | 2496.5 | 6929.6 | 1–1/1796 |
| setA-13 | 10 | 0.0410256 ± 0 | 0.0410254959 | 0.00025375 | 10/10 | 3600.0 | 4100.5 | 1–1/2000 |
| setA-14 | 10 | 0.572103669 ± 0 | 0.5176213 | 9.52316 | 10/10 | 373.9 | 9048.2 | 0–0/2216 |
| setA-15 | 10 | 0.898695808 ± 0 | 0.898695808 | 1.11022e-14 | 10/10 | 3600.7 | 4836.0 | 13–13/2500 |
| setA-16 | 10 | 0.045081995 ± 1.58e-08 | 0.0442621696 | 1.81852 | 10/10 | 1911.5 | 7612.2 | 0–0/2904 |
| setA-17 | 10 | 0.424192341 ± 0 | 0.424192341 | 0 | 10/10 | 3601.1 | 4534.9 | 13–16/2540 |
| setA-18 | 10 | 0.999998765 ± 0 | 0.999998704 | 6.1e-06 | 10/10 | 3601.4 | 4383.5 | 9–12/3000 |
| setA-19 | 10 | 0.0492037565 ± 0.000511 | 0.0468383933 | 4.79809 | 10/10 | 3600.0 | 5027.9 | 0–0/3996 |
| setA-20 | 10 | 0.991312385 ± 0 | 0.991312299 | 8.75784e-06 | 10/10 | 2410.4 | 7696.5 | 3–3/4000 |

Trạng thái dừng: {'TIME_LIMIT': 92, 'SEARCH_WALL_LIMIT': 108}.

## Phạm vi kiểm tra và dữ liệu

Kiểm tra đủ 400 định danh, mỗi định danh duy nhất, run/seed đúng (1001–1010), runner báo validated, có route và vector tải, MLU khớp max vector tải, thứ tự vector, công thức gap/cận, Budget của Step 9 và tính nhất quán chứng nhận toàn bộ từ điển. Đây là kiểm tra bản ghi; không tái dựng độc lập ECMP từ topology hoặc kiểm chứng lại chứng minh dual.

Các lần recovery có thể dùng revision và điều kiện thực thi khác nhau. Có run bị giới hạn wall trước khi dùng hết ngân sách optimize. Không dùng số liệu này làm benchmark thời gian có kiểm soát. Chọn bản ghi completed có mtime kết quả mới nhất; manifest ghi các bản trùng và đường dẫn nguồn.

- [runs.csv](runs.csv): 400 run, số liệu đầy đủ và nguồn gốc.
- [instance_statistics.csv](instance_statistics.csv), [JSON](instance_statistics.json): n, mean, SD mẫu, phương sai mẫu, min/max cho từng chỉ tiêu.
- [audit.json](audit.json): kết quả đối soát và trạng thái dừng.
- [results.json.gz](results.json.gz): 400 kết quả gốc, supervisor và nghiệm đầy đủ (srpaths, sorted_loads).
- [manifest.json](manifest.json): thời điểm thu, quy tắc chọn bản ghi và SHA-256 nguồn.
- `raw/*.json.gz`: các bản ghi completed thu từ bốn VM, giữ cả bản trùng để truy vết.

Dữ liệu nén là JSON UTF-8 gzip; có thể đọc bằng gzip/json của Python. Không cần kết nối cloud để dựng lại bảng:

```sh
python3 reports/cloud_final_20261024/rebuild.py
```
