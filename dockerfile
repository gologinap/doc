# ----------------------------------------------------------------------
# Dockerfile: MeshCentral & HAProxy cho Dự án Chính phủ trên Render.com
# Tác giả: Gemini AI
# Phiên bản: 1.0 - Tối ưu cho môi trường Render
# ----------------------------------------------------------------------

# Sử dụng hệ điều hành Ubuntu 22.04 LTS làm nền tảng ổn định
FROM ubuntu:22.04

# --- BIẾN MÔI TRƯỜNG CỐ ĐỊNH ---
ENV DEBIAN_FRONTEND=noninteractive
# Thư mục lưu trữ dữ liệu bền bỉ của MeshCentral (sẽ được gắn đĩa của Render vào)
ENV MC_DATA_DIR=/data
# Cổng nội bộ mà MeshCentral sẽ lắng nghe, HAProxy sẽ trỏ vào đây
ENV MC_INTERNAL_PORT=8080

# --- CÀI ĐẶT CÁC GÓI PHẦN MỀM CẦN THIẾT ---
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nodejs \
        npm \
        haproxy \
        curl \
        ca-certificates && \
    # Dọn dẹp cache để giảm kích thước image
    apt-get clean && rm -rf /var/lib/apt/lists/*

# --- CÀI ĐẶT MESHCENTRAL ---
RUN npm install -g meshcentral@latest

# --- TẠO CÁC THƯ MỤC CẦN THIẾT ---
RUN mkdir -p ${MC_DATA_DIR} /etc/haproxy

# --- TẠO CÁC TỆP CẤU HÌNH MẪU (TEMPLATE) ---
# Các giá trị __PORT__ và __DOMAIN_NAME__ sẽ được thay thế bằng giá trị thật lúc container khởi động.

# 1. Mẫu cấu hình HAProxy
RUN cat > /etc/haproxy/haproxy.cfg.template <<'EOF'
global
    daemon
    log stdout local0 info
defaults
    mode http
    log global
    option httplog
    option forwardfor
    timeout connect 5s
    timeout client 50s
    timeout server 50s
frontend main
    # Lắng nghe trên cổng mà Render cung cấp (__PORT__)
    bind *:__PORT__
    # Thêm header X-Forwarded-Proto vì Render đã xử lý HTTPS
    http-request add-header X-Forwarded-Proto https
    # Định tuyến dựa trên đường dẫn URL cho WebSocket và Relay
    acl is_websocket path_beg /agent.ashx /control.ashx
    acl is_relay path_beg /meshrelay.ashx
    use_backend meshcentral_ws if is_websocket
    use_backend meshcentral_relay if is_relay
    default_backend meshcentral_http
backend meshcentral_http
    server meshcentral1 127.0.0.1:${MC_INTERNAL_PORT} check
backend meshcentral_ws
    server meshcentral1 127.0.0.1:${MC_INTERNAL_PORT} check
backend meshcentral_relay
    server meshcentral1 127.0.0.1:${MC_INTERNAL_PORT} check
EOF

# 2. Mẫu cấu hình MeshCentral
RUN cat > /config.json.template <<EOF
{
    "_comment": "Cấu hình tự động cho Render.com",
    "settings": {
        "Port": ${MC_INTERNAL_PORT},
        "TlsOffload": "127.0.0.1",
        "AllowLoginToken": true,
        "AllowFraming": true
    },
    "domains": {
        "": {
            "title": "Hệ thống Quản lý Chính phủ",
            "certUrl": "https://__DOMAIN_NAME__"
        }
    },
    "_comment_data": "Chuyển hướng toàn bộ dữ liệu vào thư mục /data để lưu trữ bền bỉ",
    "datastore": {
        "dbPath": "${MC_DATA_DIR}/meshcentral.db",
        "filesPath": "${MC_DATA_DIR}/meshcentral-files",
        "eventsPath": "${MC_DATA_DIR}/meshcentral-events"
    }
}
EOF

# --- TẠO KỊCH BẢN KHỞI ĐỘNG (ENTRYPOINT) ---
# Kịch bản này sẽ tự động cấu hình và khởi chạy 2 dịch vụ
RUN cat > /entrypoint.sh <<'EOF'
#!/bin/bash
# Thoát ngay lập tức nếu có lỗi
set -e

# Đọc các biến môi trường từ Render, nếu không có thì dùng giá trị mặc định (để test local)
RENDER_PORT=${PORT:-10000}
RENDER_HOSTNAME=${RENDER_EXTERNAL_HOSTNAME:-localhost}

echo "--- Khởi tạo môi trường cho Render.com ---"
echo "Tên miền công khai: $RENDER_HOSTNAME"
echo "Lắng nghe trên cổng: $RENDER_PORT"
echo "-----------------------------------------"

# Dùng sed để thay thế placeholder trong file template bằng giá trị thực
sed "s/__PORT__/$RENDER_PORT/g" /etc/haproxy/haproxy.cfg.template > /etc/haproxy/haproxy.cfg
sed "s/__DOMAIN_NAME__/$RENDER_HOSTNAME/g" /config.json.template > ${MC_DATA_DIR}/config.json

# Khởi động HAProxy ở chế độ nền
echo "-> Khởi động HAProxy..."
haproxy -f /etc/haproxy/haproxy.cfg &

# Khởi động MeshCentral ở chế độ tiền cảnh
# Lệnh exec giúp MeshCentral trở thành tiến trình chính, nhận tín hiệu tắt/mở từ Render
echo "-> Khởi động MeshCentral..."
exec node /usr/lib/node_modules/meshcentral --config ${MC_DATA_DIR}/config.json
EOF

# --- CẤU HÌNH HOÀN TẤT ---
# Cấp quyền thực thi cho kịch bản khởi động
RUN chmod +x /entrypoint.sh

# Expose cổng mặc định của Render để tham khảo
EXPOSE 10000

# Lệnh sẽ được chạy khi container khởi động
CMD ["/entrypoint.sh"]
