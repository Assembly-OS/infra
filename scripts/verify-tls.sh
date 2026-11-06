#!/usr/bin/env bash
set -Eeuo pipefail
domain="${1:-assemblyos.uz}"
origin="${2:-65.108.142.153}"
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$origin" =~ ^[0-9.]+$ ]] || exit 2
# No insecure flag: the public certificate does not prove origin trust.
curl --noproxy '*' --fail --silent --show-error --connect-timeout 5 --max-time 20 \
  --resolve "$domain:443:$origin" "https://$domain/api/healthz" -o /dev/null
curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
  "https://$domain/api/healthz" -o /dev/null
echo "Origin certificate and public HTTPS verified"
