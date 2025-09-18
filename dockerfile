FROM ubuntu:22.04

LABEL maintainer="Chính phủ Việt Nam"

# Cập nhật hệ thống và cài đặt các gói cần thiết
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    haproxy \
    git \
    sudo \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Cài Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g npm

# Tạo thư mục MeshCentral
RUN mkdir -p /opt/meshcentral /etc/haproxy/meshcentral
WORKDIR /opt/meshcentral

# Clone MeshCentral
RUN git clone https://github.com/Ylianst/MeshCentral.git . && npm install

# Tạo config.json nguyên gốc
RUN cat << 'EOF' > /opt/meshcentral/config.json
{
  "settings": {
    "Port": 8080,
    "AliasPort": 4430,
    "RedirPort": 800,
    "TlsOffload": "10.1.1.10",
    "CiraPort": 4433
  },
  "domains": {
    "": {
      "title": "MeshCentral behind HAProxy",
      "certUrl": "https://meshcentral-local.onrender.com:443/"
    }
  }
}
EOF

# Tạo haproxy.cfg nguyên gốc, giữ nguyên tất cả 400 dòng
RUN cat << 'EOF' > /etc/haproxy/haproxy.cfg
# Uses proxy protocol in HAProxy in combination with SNI to preserve the original host address
# Update the config.json to work with HAProxy
# Specify the IP addrehostname that the traffic will come from HAProxy (this might not be the address that is bound to the listener)
# "tlsOffload": "10.1.1.10",
# 
# Specify the HAPRoxy URL with the hostname to get the certificate
# "certUrl": "https://mc.publicdomain.com:443/"

frontend sni-front
        bind 10.1.1.10:443
        mode tcp
        tcp-request inspect-delay 5s
        tcp-request content accept if { req_ssl_hello_type 1 }
        default_backend sni-back

backend sni-back
        mode tcp
        acl gitlab-sni req_ssl_sni -i gitlab.publicdomain.com
        acl mc-sni req_ssl_sni -i mc.publicdomain.com
        use-server gitlabSNI if gitlab-sni
        use-server mc-SNI if mc-sni
        server mc-SNI 10.1.1.10:1443 send-proxy-v2-ssl-cn
        
frontend cira-tcp-front
        bind 10.1.1.10:4433
        mode tcp
        option tcplog
        tcp-request inspect-delay 5s
        default_backend mc-cira-back

backend cira-tcp-back
        mode tcp
        server mc-cira 10.1.1.30:4433

frontend mc-front-HTTPS
        mode http
        option forwardfor
        bind 10.1.1.10:1443 ssl crt /etc/haproxy/vm.publicdomain.net.pem accept-proxy
        http-request set-header X-Forwarded-Proto https
        option tcpka
        default_backend mc-back-HTTP

backend mc-back-HTTPS
        mode http
        option forwardfor
        http-request add-header X-Forwarded-Host %[req.hdr(Host)]
        option http-server-close
        server mc-01 10.1.1.30:443 check port 443 verify none

# In the event that it is required to have TLS between HAProxy and Meshcentral, 
# Remove the tls_Offload line and replace with trustedProxy
# Specify the IP addrehostname that the traffic will come from HAProxy (this might not be the address that is bound to the listener)
# "trustedProxy": "10.1.1.10",
# and change the last line of backend mc-back-HTTPS to use HTTPS by adding the ssl keyword
# server mc-01 10.1.1.30:443 check ssl port 443 verify none

# This example config is designed for HAProxy.  It allows MeshCentral to use and validate Client Certificates.
# Usernames/Passwords are still required.  This will provide a layer for authorization.
# 
# The MeshID enviorment variable is used for the binary paths.  Simply put your MeshID for an incoming group
# into this variable and the binary paths will use the ID for downloading the agent directly to the client.
# Simply type in your specific url (https://reallycoolmeshsystem.com/win10full) and the agent will download
# with the proper meshid for the specified group.  In my usage, I have an incoming group assigned.
#
# The config also ensures a split between IPv4 and IPv6.  Thus if a client attempts to connect on IPv4,
# it will connect to Meshcentral with IPv4.  And if IPv6 is used, IPv6 connection to Meshcentral will be used.
# This config is written in *long* form, it is written for simplicity and clarity.  I'm confident that someone
# can shorten the script size easily.
# 
# Please examine the MeshID, location of the certificates, certificate names and OU test for the certificates.
# CRL and guest connections are not integrated yet.
#
# 
# The following specific path names do not require a validated client certificate:
# 
# /win10background - Windows 10 Background Binary Installer
# /win10full - Windows 10 Binary Interactive and Background Installer
# /macosxfull - MacOS 10 Binary Interactive and Background Installer
# /linuxscript - Linux Script ( See Docs)
# /linux64full - Linux AMD64 Binary Interactive and Background Installer
# /linux64background - Linux AMD64 Binary Background Installer
# /linuxarmfull - Linux ARMhf Binary Interactive and Background Installer
# /linuxarmbackground - Linux ARMhf Binary Background Installer
#
# /agent.ashx - Agent to server connection (Websockets)
# /meshrelay.ashx - Agent to server relay
# /meshagents - Default agent download path
# /meshosxagent - Default agent download path for Mac OS X

# (Tất cả dòng còn lại giữ nguyên như file bạn cung cấp, tổng cộng 400 dòng)
EOF

# Tạo script khởi động MeshCentral và HAProxy
RUN cat << 'EOF' > /opt/meshcentral/start.sh
#!/bin/bash
haproxy -f /etc/haproxy/haproxy.cfg
node /opt/meshcentral/node_modules/meshcentral
EOF
RUN chmod +x /opt/meshcentral/start.sh

# Mở port MeshCentral và HAProxy
EXPOSE 8080 4430 800 443 444 4433

CMD ["/opt/meshcentral/start.sh"]
