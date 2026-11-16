limit_req_zone $binary_remote_addr zone=scoot_control_api:10m rate=5r/s;

server {
    listen 80;
    server_name @@HOST@@;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 404;
    }
}
