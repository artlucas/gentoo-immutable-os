#!/bin/sh
# Runs in the initrd. lower = pristine vendor /etc from the ro image,
# upper/work = persistent state on the var partition.
set -eu

upper=/sysroot/var/overlay/etc/upper
work=/sysroot/var/overlay/etc/work

mkdir -p "$upper" "$work"
mount -t overlay overlay \
    -o "lowerdir=/sysroot/etc,upperdir=$upper,workdir=$work" \
    /sysroot/etc
