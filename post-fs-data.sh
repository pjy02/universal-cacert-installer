#!/system/bin/sh

exec > /data/local/tmp/CustomCACert.log
exec 2>&1

set -x

MODDIR=${0%/*}

RAW_CERT_DIR="${MODDIR}/system/etc/security/cacerts-raw"
CERT_DIR="${MODDIR}/system/etc/security/cacerts"
INSTALL_LOG_TAG="[Universal CA]"

find_openssl() {
    bundled_openssl="${MODDIR}/tools/openssl/openssl-arm64"
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

ensure_named_certs() {
    [ -d "$RAW_CERT_DIR" ] || return 0

    mkdir -p "$CERT_DIR"

    find_openssl
    if [ -z "$OPENSSL_BIN" ]; then
        echo "${INSTALL_LOG_TAG} openssl not found; skipping raw cert processing"
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
            echo "${INSTALL_LOG_TAG} failed to parse cert: ${cert}"
            continue
        fi

        if cert_already_installed "$cert" "$hash"; then
            skipped=$((skipped + 1))
            echo "${INSTALL_LOG_TAG} cert already installed, skipping: ${cert}"
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

    echo "${INSTALL_LOG_TAG} raw certs processed: total=${total}, installed=${copied}, skipped=${skipped}, failed=${failed}"
    if [ "$failed" -gt 0 ]; then
        echo "${INSTALL_LOG_TAG} failed cert list:${failed_list}"
    fi
}

set_context() {
    [ "$(getenforce)" = "Enforcing" ] || return 0

    default_selinux_context=u:object_r:system_file:s0
    selinux_context=$(ls -Zd $1 | awk '{print $1}')

    if [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ]; then
        chcon -R $selinux_context $2
    else
        chcon -R $default_selinux_context $2
    fi
}

ensure_named_certs

echo "${INSTALL_LOG_TAG} applying ownership and SELinux context"
chown -R 0:0 "${CERT_DIR}"
set_context /system/etc/security/cacerts "${CERT_DIR}"

# Android 14 support
# Since Magisk ignore /apex for module file injections, use non-Magisk way
if [ -d /apex/com.android.conscrypt/cacerts ]; then
    echo "${INSTALL_LOG_TAG} detected APEX CACerts, preparing tmpfs overlay"
    # Clone directory into tmpfs
    rm -f /data/local/tmp/sys-ca-copy
    mkdir -p /data/local/tmp/sys-ca-copy
    mount -t tmpfs tmpfs /data/local/tmp/sys-ca-copy
    cp -f /apex/com.android.conscrypt/cacerts/* /data/local/tmp/sys-ca-copy/

    # Do the same as in Magisk module
    cp -f "${CERT_DIR}"/* /data/local/tmp/sys-ca-copy
    chown -R 0:0 /data/local/tmp/sys-ca-copy
    set_context /apex/com.android.conscrypt/cacerts /data/local/tmp/sys-ca-copy

    # Mount directory inside APEX if it is valid, and remove temporary one.
    CERTS_NUM="$(ls -1 /data/local/tmp/sys-ca-copy | wc -l)"
    if [ "$CERTS_NUM" -gt 10 ]; then
        echo "${INSTALL_LOG_TAG} bind-mounting updated CA store into APEX"
        mount --bind /data/local/tmp/sys-ca-copy /apex/com.android.conscrypt/cacerts
        for pid in 1 $(pgrep zygote) $(pgrep zygote64); do
            nsenter --mount=/proc/${pid}/ns/mnt -- \
                mount --bind /data/local/tmp/sys-ca-copy /apex/com.android.conscrypt/cacerts
        done
    else
        echo "${INSTALL_LOG_TAG} cancelling CA replacement due to safety (count=${CERTS_NUM})"
    fi
    umount /data/local/tmp/sys-ca-copy
    rmdir /data/local/tmp/sys-ca-copy
    echo "${INSTALL_LOG_TAG} APEX CA handling complete"
fi
