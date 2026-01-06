#!/system/bin/sh

RAW_CERT_DIR="${MODPATH}/system/etc/security/cacerts-raw"
CERT_DIR="${MODPATH}/system/etc/security/cacerts"
INSTALL_LOG_TAG="[Universal CA]"

find_openssl() {
    bundled_openssl="${MODPATH}/tools/openssl/openssl-arm64"
    if [ -f "$bundled_openssl" ]; then
        chmod 0755 "$bundled_openssl" 2>/dev/null || true
    fi

    if [ -x "$bundled_openssl" ]; then
        OPENSSL_BIN="$bundled_openssl"
        OPENSSL_SUB=""
        return 0
    fi

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

cert_already_installed() {
    cert_path="$1"
    cert_hash="$2"
    for existing in "${CERT_DIR}/${cert_hash}."*; do
        [ -f "$existing" ] || continue
        if cmp -s "$cert_path" "$existing"; then
            return 0
        fi
    done
    return 1
}

generate_named_certs() {
    [ -d "$RAW_CERT_DIR" ] || return 0

    mkdir -p "$CERT_DIR"

    find_openssl
    if [ -z "$OPENSSL_BIN" ]; then
        ui_print "${INSTALL_LOG_TAG} 未找到 openssl，跳过 cacerts-raw 处理"
        return 0
    fi

    total=0
    copied=0
    skipped=0
    failed=0
    failed_list=""

    for cert in "$RAW_CERT_DIR"/*; do
        [ -f "$cert" ] || continue
        total=$((total + 1))

        hash="$(openssl_subject_hash "$cert")"
        if [ -z "$hash" ]; then
            failed=$((failed + 1))
            failed_list="${failed_list} ${cert}"
            ui_print "${INSTALL_LOG_TAG} 无法解析证书：$cert"
            continue
        fi

        if cert_already_installed "$cert" "$hash"; then
            skipped=$((skipped + 1))
            ui_print "${INSTALL_LOG_TAG} 证书已存在，跳过：$cert"
            continue
        fi

        if cert_already_installed "$cert" "$hash"; then
            continue
        fi

        idx=0
        dest="${CERT_DIR}/${hash}.${idx}"
        while [ -e "$dest" ]; do
            idx=$((idx + 1))
            dest="${CERT_DIR}/${hash}.${idx}"
        done

        cp -f "$cert" "$dest"
        copied=$((copied + 1))
    done

    ui_print "${INSTALL_LOG_TAG} raw 证书处理完成：总数=${total}，已安装=${copied}，已跳过=${skipped}，失败=${failed}"
    if [ "$failed" -gt 0 ]; then
        ui_print "${INSTALL_LOG_TAG} 失败证书列表:${failed_list}"
    fi
}

generate_named_certs

if [ ! -e /data/adb/metamodule ]; then
    ui_print "- 检测到未安装元模块，模块文件不会被挂载"
    ui_print "- 请安装 meta-overlayfs 等元模块后重启"
fi
