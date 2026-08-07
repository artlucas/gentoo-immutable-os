#!/bin/bash
# shellcheck disable=SC2154  # moddir/initdir/systemdsystemunitdir/SYSTEMCTL come from dracut
# dracut module: mount the /etc overlay (upper on /var) before switch-root (plan/01).

check() {
    return 0
}

depends() {
    echo systemd
}

install() {
    inst_script "$moddir/etc-overlay.sh" /usr/bin/etc-overlay
    inst_simple "$moddir/etc-overlay.service" "$systemdsystemunitdir/etc-overlay.service"
    $SYSTEMCTL -q --root "$initdir" enable etc-overlay.service
}
