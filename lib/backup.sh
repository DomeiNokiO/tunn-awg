#!/usr/bin/env bash
# Backup + retention (default 7 daily archives).

backup_now() {
    local ts dir out
    ts="$(date +%Y%m%d_%H%M%S)"
    dir="/var/lib/tunn-awg/backup"
    out="$dir/vpn-$ts.tar.gz"
    mkdir -p "$dir"

    tar -czf "$out" \
        --exclude='*.png' \
        /etc/wireguard \
        /etc/ppp/chap-secrets \
        /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d \
        /etc/xl2tpd \
        "$TUNN_ETC" 2>/dev/null || true

    # Retensi: simpan 7 terbaru.
    ls -1t "$dir"/vpn-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f

    # Hook opsional untuk push ke storage remote (rclone/scp/dsb).
    local hook; hook="$(config_get POST_BACKUP_CMD 2>/dev/null || true)"
    if [[ -n "$hook" ]]; then
        BACKUP_FILE="$out" bash -c "$hook" || log_warn "POST_BACKUP_CMD gagal."
    fi

    echo "$out"
}

backup_list() {
    ls -1t /var/lib/tunn-awg/backup/vpn-*.tar.gz 2>/dev/null || echo "(kosong)"
}
