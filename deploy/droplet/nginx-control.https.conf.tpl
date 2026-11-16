limit_req_zone $binary_remote_addr zone=scoot_control_api:10m rate=5r/s;

server {
    listen 80;
    server_name @@HOST@@;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name @@HOST@@;

    ssl_certificate     /etc/letsencrypt/live/@@HOST@@/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/@@HOST@@/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /opt/scoot/platform/web;
    index index.html;
    client_max_body_size 5m;
    limit_req_status 429;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_min_length 1024;
    gzip_types application/javascript application/json application/wasm text/css image/svg+xml font/ttf font/otf application/octet-stream;

    add_header Strict-Transport-Security "max-age=300" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com https://apis.google.com 'sha256-NkpTxSGMi05jgrFoXnwTFGf0PvxizPWYurcmzXCgGow=' 'sha256-S5w3bf0112zCmldQk0sJAuk2bRjz2mf3pveQpuvpxBc=' 'sha256-y8ewIXLsYGY74/TPAV9VLq1ALfbWUlDDuzPDgjayMss=' 'sha256-zNtG3Nz7gX1J8b9JUW3RcKrApDuGs37PAgyFfYZrySU=' 'sha256-3vUxyF1PHtv38LtuCkWn5x58wvN7mDkIAmeheHW7vak=' 'sha256-F5bYyiydOiGOaoYTXYzGjUKs8KBqqqO6TPjHnEwT5uY=' 'sha256-zO4835fVEjaE3P5Vr5SZf4pcJtfTjNT7wHg9EZkomWg=' 'sha256-O8dnxpH3DbDprAevW/u3E5ltnbMe2CEpty527uttc2U='; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self' https://*.googleapis.com https://www.gstatic.com https://fonts.gstatic.com; frame-src https://*.firebaseapp.com; worker-src 'self' blob:; base-uri 'self'; object-src 'none'; form-action 'self'" always;

    location = /health {
        limit_req zone=scoot_control_api burst=20 nodelay;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://127.0.0.1:8100;
    }

    location /v1/ {
        limit_req zone=scoot_control_api burst=20 nodelay;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://127.0.0.1:8100;
    }

    location /staff/ {
        limit_req zone=scoot_control_api burst=10 nodelay;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass http://127.0.0.1:8100;
    }

    location / {
        expires -1;
        try_files $uri $uri/ /index.html;
    }
}
