#!/system/bin/sh

RAW_CERT_DIR="${MODPATH}/system/etc/security/cacerts-raw"
CERT_DIR="${MODPATH}/system/etc/security/cacerts"

find_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        OPENSSL_BIN="openssl"
        OPENSSL_SUB=""
    elif command -v toybox >/dev/null 2>&1 && toybox openssl version >/dev/null 2>&1; then
        OPENSSL_BIN="toybox"
        OPENSSL_SUB="openssl"
    else
        OPENSSL_BIN=""
        OPENSSL_SUB=""
    fi
}

openssl_subject_hash() {
    cert_path="$1"
    if [ -z "$OPENSSL_BIN" ]; then
        return 1
    fi

    if [ -n "$OPENSSL_SUB" ]; then
        "$OPENSSL_BIN" "$OPENSSL_SUB" x509 -inform PEM -subject_hash_old -in "$cert_path" 2>/dev/null | head -n 1
    else
        "$OPENSSL_BIN" x509 -inform PEM -subject_hash_old -in "$cert_path" 2>/dev/null | head -n 1
    fi
}

generate_named_certs() {
    [ -d "$RAW_CERT_DIR" ] || return 0

    mkdir -p "$CERT_DIR"

    find_openssl
    if [ -z "$OPENSSL_BIN" ]; then
        ui_print "- 未找到 openssl，跳过 cacerts-raw 处理"
        return 0
    fi

    for cert in "$RAW_CERT_DIR"/*; do
        [ -f "$cert" ] || continue

        hash="$(openssl_subject_hash "$cert")"
        if [ -z "$hash" ]; then
            ui_print "- 无法解析证书：$cert"
            continue
        fi

        idx=0
        dest="${CERT_DIR}/${hash}.${idx}"
        while [ -e "$dest" ]; do
            idx=$((idx + 1))
            dest="${CERT_DIR}/${hash}.${idx}"
        done

        cp -f "$cert" "$dest"
    done
}

generate_named_certs

if [ ! -e /data/adb/metamodule ]; then
    ui_print "- 检测到未安装元模块，模块文件不会被挂载"
    ui_print "- 请安装 meta-overlayfs 等元模块后重启"
fi
