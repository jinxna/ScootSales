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

    root @@ROOT@@;
    index index.html;
    client_max_body_size 1k;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_min_length 1024;
    gzip_types text/css application/javascript image/svg+xml;

    add_header Strict-Transport-Security "max-age=300" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; img-src 'self' data:; media-src 'self' data:; font-src 'self' data: https://fonts.gstatic.com; connect-src 'self'; base-uri 'self'; object-src 'none'; form-action 'none'; frame-ancestors 'none'" always;

    location / {
        limit_except GET HEAD {
            deny all;
        }
        expires 10m;
        try_files $uri $uri.html $uri/ =404;
    }
}
