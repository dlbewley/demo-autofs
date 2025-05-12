#!/bin/bash

exec automount \
  --force \
  --foreground \
  --timeout 0 \
  --dont-check-daemon \
  --debug
