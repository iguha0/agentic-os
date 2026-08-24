#!/bin/sh
# zap — quick Lightning invoice request (agent shell + CLI friendly)
#   zap <amount_sats> [memo]
exec /usr/local/bin/lnurl-pay request "$1" "${2:-agentic zap}"
