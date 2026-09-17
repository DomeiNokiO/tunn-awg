#!/usr/bin/env bash
# Expiry enforcement: suspend expired, delete after grace period.

expiry_run() {
    local grace
    grace="$(config_get GRACE_DAYS)"; grace="${grace:-3}"

    # Warning H-3.
    while read -r type name; do
        [[ -z "$name" ]] && continue
        _notify "⚠️  ${type^^} '$name' akan expired dalam <=3 hari."
    done < <(sqlite3 -separator ' ' "$TUNN_DB" \
        "SELECT type,name FROM users \
         WHERE expires_at IS NOT NULL AND suspended=0 \
           AND date(expires_at) BETWEEN date('now','+1 day') AND date('now','+3 day');" 2>/dev/null)

    # Suspend jika sudah expired.
    while read -r type name pubkey; do
        [[ -z "$name" ]] && continue
        _suspend_user "$type" "$name" "$pubkey"
        sqlite3 "$TUNN_DB" "UPDATE users SET suspended=1 WHERE type='$type' AND name='$name';" 2>/dev/null || true
        _notify "⛔ ${type^^} '$name' di-suspend: masa aktif habis."
    done < <(sqlite3 -separator '|' "$TUNN_DB" \
        "SELECT type,name,COALESCE(pubkey,'') FROM users \
         WHERE expires_at IS NOT NULL AND suspended=0 AND date(expires_at) <= date('now');" 2>/dev/null | tr '|' ' ')

    # Delete jika lewat grace period.
    while read -r type name; do
        [[ -z "$name" ]] && continue
        case "$type" in
            wg)   wg_del "$name" >/dev/null 2>&1 || true ;;
            l2tp) l2tp_del "$name" >/dev/null 2>&1 || true ;;
        esac
        _notify "🗑️  ${type^^} '$name' dihapus (grace $grace hari terlewat)."
    done < <(sqlite3 -separator ' ' "$TUNN_DB" \
        "SELECT type,name FROM users \
         WHERE expires_at IS NOT NULL AND suspended=1 \
           AND date(expires_at,'+$grace days') <= date('now');" 2>/dev/null)
}

_suspend_user() {
    local type="$1" name="$2" pubkey="$3"
    case "$type" in
        wg)
            [[ -n "$pubkey" ]] && wg set wg0 peer "$pubkey" remove 2>/dev/null || true
            ;;
        l2tp)
            sed -i "s|^\"\?$name\"\?\([[:space:]]\+\)l2tpd|# suspended \"$name\"\1l2tpd|" /etc/ppp/chap-secrets
            ;;
    esac
}
