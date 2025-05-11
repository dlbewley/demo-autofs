#!/bin/bash

# Install automounter and nfs rpms
dnf install --assumeyes \
  autofs \
  nfs-utils
#  openldap-clients # currently unused

mkdir -p /mnt/automount

# Start the autofs
exec automount \
  --force \
  --foreground \
  --timeout 0 \
  --dont-check-daemon \
  --debug
