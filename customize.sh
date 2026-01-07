#!/system/bin/sh

RAW_CERT_DIR="${MODPATH}/cacerts-raw"
CERT_DIR="${MODPATH}/system/etc/security/cacerts"
INSTALL_LOG_TAG="[Universal CA]"
OLD_MODULE_DIR="/data/adb/modules/universal-cacert-installer"
OLD_CERT_DIR="${OLD_MODULE_DIR}/system/etc/security/cacerts"
OLD_RAW_CERT_DIR="${OLD_MODULE_DIR}/cacerts-raw"

find_openssl() {
    bundled_openssl=""
    device_abi="$(getprop ro.product.cpu.abi 2>/dev/null)"
    case "$device_abi" in
        arm64-v8a|aarch64)
            bundled_openssl="${MODPATH}/tools/openssl/openssl-arm64"
            ;;
        armeabi*|armv7*)
            bundled_openssl="${MODPATH}/tools/openssl/openssl-arm"
            ;;
        x86_64)
            bundled_openssl="${MODPATH}/tools/openssl/openssl-x64"
            ;;
        x86)
            bundled_openssl="${MODPATH}/tools/openssl/openssl-x86"
            ;;
    esac

    for candidate in \
        "$bundled_openssl" \
        "${MODPATH}/tools/openssl/openssl-arm64" \
        "${MODPATH}/tools/openssl/openssl-arm" \
        "${MODPATH}/tools/openssl/openssl-x64" \
        "${MODPATH}/tools/openssl/openssl-x86"; do
        [ -n "$candidate" ] || continue
        if [ -f "$candidate" ]; then
            chmod 0755 "$candidate" 2>/dev/null || true
        fi
        if [ -x "$candidate" ]; then
            OPENSSL_BIN="$candidate"
            OPENSSL_SUB=""
            return 0
        fi
    done

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

raw_cert_already_installed() {
    cert_path="$1"
    for existing in "${RAW_CERT_DIR}"/*; do
        [ -f "$existing" ] || continue
        [ "$(basename "$existing")" = ".gitkeep" ] && continue
        if cmp -s "$cert_path" "$existing"; then
            return 0
        fi
    done
    return 1
}

has_old_certs() {
    for existing in "${OLD_CERT_DIR}"/* "${OLD_RAW_CERT_DIR}"/*; do
        [ -f "$existing" ] || continue
        [ "$(basename "$existing")" = ".gitkeep" ] && continue
        return 0
    done
    return 1
}

copy_old_raw_cert() {
    source_path="$1"
    mode="$2"
    filename="$(basename "$source_path")"

    mkdir -p "$RAW_CERT_DIR"

    if raw_cert_already_installed "$source_path"; then
        ui_print "${INSTALL_LOG_TAG} raw 证书已存在，跳过：$filename"
        return 0
    fi

    dest="${RAW_CERT_DIR}/${filename}"
    if [ -e "$dest" ] && [ "$mode" = "preserve" ]; then
        idx=0
        dest="${RAW_CERT_DIR}/${filename}.${idx}"
        while [ -e "$dest" ]; do
            idx=$((idx + 1))
            dest="${RAW_CERT_DIR}/${filename}.${idx}"
        done
    fi

    cp -f "$source_path" "$dest"
    ui_print "${INSTALL_LOG_TAG} 已复制 raw 证书：$filename"
}

copy_old_named_cert() {
    source_path="$1"
    mode="$2"
    filename="$(basename "$source_path")"
    cert_hash="${filename%%.*}"

    mkdir -p "$CERT_DIR"

    if cert_already_installed "$source_path" "$cert_hash"; then
        ui_print "${INSTALL_LOG_TAG} 证书已存在，跳过：$filename"
        return 0
    fi

    dest="${CERT_DIR}/${filename}"
    if [ -e "$dest" ] && [ "$mode" = "preserve" ]; then
        idx=0
        dest="${CERT_DIR}/${cert_hash}.${idx}"
        while [ -e "$dest" ]; do
            idx=$((idx + 1))
            dest="${CERT_DIR}/${cert_hash}.${idx}"
        done
    fi

    cp -f "$source_path" "$dest"
    ui_print "${INSTALL_LOG_TAG} 已复制证书：$filename"
}

maybe_import_old_certs() {
    [ -d "$OLD_MODULE_DIR" ] || return 0
    has_old_certs || return 0

    if ! command -v getevent >/dev/null 2>&1; then
        ui_print "${INSTALL_LOG_TAG} 未检测到音量键支持，跳过交互"
        return 0
    fi

    ui_print " "
    ui_print "${INSTALL_LOG_TAG} 检测到旧证书，可选择导入到新模块"
    ui_print "${INSTALL_LOG_TAG} 音量+：导入旧证书  音量-：跳过导入"
    if ! chooseport_compat "导入旧证书" "跳过导入"; then
        ui_print "${INSTALL_LOG_TAG} 已选择跳过旧证书导入"
        return 0
    fi

    sleep 1

    ui_print "${INSTALL_LOG_TAG} 选择导入方式"
    ui_print "${INSTALL_LOG_TAG} 音量+：复制并替换  音量-：复制并保留两个证书"
    if chooseport_compat "复制并替换" "复制并保留两个证书"; then
        mode="replace"
    else
        mode="preserve"
    fi

    for cert in "${OLD_CERT_DIR}"/*; do
        [ -f "$cert" ] || continue
        [ "$(basename "$cert")" = ".gitkeep" ] && continue
        copy_old_named_cert "$cert" "$mode"
    done

    for cert in "${OLD_RAW_CERT_DIR}"/*; do
        [ -f "$cert" ] || continue
        [ "$(basename "$cert")" = ".gitkeep" ] && continue
        copy_old_raw_cert "$cert" "$mode"
    done
}

chooseport_compat() {
    timeout_s=10
    start_time="$(date +%s)"
    end_time=$((start_time + timeout_s))
    primary_label="${1:-确认}"
    secondary_label="${2:-取消}"

    ui_print "${INSTALL_LOG_TAG} 请按音量键进行选择 (等待${timeout_s}秒)..."
    ui_print "  [+] 音量上: ${primary_label}"
    ui_print "  [-] 音量下: ${secondary_label}"
    if command -v timeout >/dev/null 2>&1; then
        timeout 0.5 getevent -qlc 20 >/dev/null 2>&1
    fi
    if command -v getevent >/dev/null 2>&1; then
        while [ "$(date +%s)" -lt "$end_time" ]; do
            if command -v timeout >/dev/null 2>&1; then
                event="$(timeout 1 getevent -qlc 1 2>/dev/null)"
            else
                event="$(getevent -qlc 1 2>/dev/null)"
            fi
            echo "$event" | grep -q "KEY_VOLUMEUP" && return 0
            echo "$event" | grep -q "KEY_VOLUMEDOWN" && return 1
        done
        ui_print "${INSTALL_LOG_TAG} ⏳ 等待超时，默认导入旧证书"
        return 0
    fi

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

maybe_import_old_certs
generate_named_certs

if [ ! -e /data/adb/metamodule ]; then
    ui_print "- 检测到未安装元模块，模块文件不会被挂载"
    ui_print "- 请安装 meta-overlayfs 等元模块后重启"
fi
