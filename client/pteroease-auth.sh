#!/usr/bin/env bash
set -euo pipefail
umask 077

APP="pteroease-auth"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pteroease"
CONFIG_FILE="$CONFIG_DIR/auth-url"
TOKEN_FILE="$CONFIG_DIR/session-token"
BASE_URL="${PTEROEASE_AUTH_URL:-}"

die(){ printf 'Error: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
need curl
need python3

if [[ -z "$BASE_URL" && -f "$CONFIG_FILE" ]]; then BASE_URL="$(cat "$CONFIG_FILE")"; fi
trim_url(){ BASE_URL="${BASE_URL%/}"; }
validate_url(){
  trim_url
  [[ "$BASE_URL" == https://* ]] || die "Set PTEROEASE_AUTH_URL to your HTTPS Worker URL."
  [[ "$BASE_URL" != *" "* && "$BASE_URL" != *$'\n'* ]] || die "Invalid Worker URL."
}

request_json(){
  local method="$1" path="$2" token="${3:-}" data="${4:-}"
  local tmp status
  tmp="$(mktemp)"
  local args=(-sS --connect-timeout 10 --max-time 30 -X "$method" "$BASE_URL$path" -H 'Accept: application/json' -H 'Content-Type: application/json' -o "$tmp" -w '%{http_code}')
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
  [[ -n "$data" ]] && args+=(--data-binary "$data")
  status="$(curl "${args[@]}")" || { rm -f "$tmp"; die "Network request failed."; }
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    python3 - "$tmp" "$status" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print(f"HTTP {sys.argv[2]}: {d.get('error','Request failed')}",file=sys.stderr)
except Exception: print(f"HTTP {sys.argv[2]}: Request failed",file=sys.stderr)
PY
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

json_field(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1], ""))' "$1"; }
load_token(){ [[ -f "$TOKEN_FILE" ]] || die "Not signed in. Run: $0 login"; TOKEN="$(cat "$TOKEN_FILE")"; [[ -n "$TOKEN" ]] || die "Empty session. Run: $0 login"; }

cmd="${1:-help}"
case "$cmd" in
  configure)
    read -r -p "Cloudflare Worker HTTPS URL (https://...workers.dev): " BASE_URL
    validate_url
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    printf '%s\n' "$BASE_URL" > "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
    printf 'Saved Worker URL to %s\n' "$CONFIG_FILE"
    ;;
  login)
    validate_url
    read -r -p "Approved account email: " email
    read -r -s -p "Password: " password; printf '\n'
    payload="$(python3 -c 'import json,sys; print(json.dumps({"email":sys.argv[1],"password":sys.argv[2]}))' "$email" "$password")"
    unset password
    response="$(request_json POST /api/cli/login "" "$payload")"
    TOKEN="$(printf '%s' "$response" | json_field token)"
    [[ -n "$TOKEN" ]] || die "Server did not return a session token."
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    printf '%s' "$TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
    printf 'Signed in. Session token saved with owner-only permissions.\n'
    ;;
  status)
    validate_url; load_token
    request_json GET /api/me "$TOKEN" | python3 -c 'import json,sys; d=json.load(sys.stdin); u=d["user"]; print("Email:",u["email"]); print("Role:",u["role"]); print("Approved:",u["approved"])'
    ;;
  users)
    validate_url; load_token
    request_json GET /api/admin/users "$TOKEN" | python3 -m json.tool
    ;;
  approve)
    validate_url; load_token
    [[ -n "${2:-}" ]] || die "Usage: $0 approve USER_ID"
    payload="$(python3 -c 'import json,sys; print(json.dumps({"userId":sys.argv[1]}))' "$2")"
    request_json POST /api/admin/users/approve "$TOKEN" "$payload" | python3 -m json.tool
    ;;
  revoke)
    validate_url; load_token
    [[ -n "${2:-}" ]] || die "Usage: $0 revoke USER_ID"
    payload="$(python3 -c 'import json,sys; print(json.dumps({"userId":sys.argv[1]}))' "$2")"
    request_json POST /api/admin/users/revoke "$TOKEN" "$payload" | python3 -m json.tool
    ;;
  logout)
    validate_url
    if [[ -f "$TOKEN_FILE" ]]; then
      TOKEN="$(cat "$TOKEN_FILE")"
      request_json POST /api/logout "$TOKEN" '{}' >/dev/null || true
      rm -f "$TOKEN_FILE"
    fi
    printf 'Local session removed.\n'
    ;;
  dashboard)
    validate_url
    printf 'Opening dashboard URL: %s\n' "$BASE_URL"
    if command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$BASE_URL"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$BASE_URL"
    else printf '%s\n' "$BASE_URL"; fi
    ;;
  help|--help|-h)
    cat <<EOF
PteroEase Cloudflare Auth client
Usage:
  $0 configure             Save your HTTPS Worker URL
  $0 login                 Sign in as an approved user
  $0 status                Show current account and role
  $0 users                 List users (admin only)
  $0 approve USER_ID       Approve a pending account (admin only)
  $0 revoke USER_ID        Revoke an account and its sessions (admin only)
  $0 dashboard             Open the management dashboard
  $0 logout                Revoke current session and remove local token
EOF
    ;;
  *) die "Unknown command: $cmd. Run '$0 help'." ;;
esac
