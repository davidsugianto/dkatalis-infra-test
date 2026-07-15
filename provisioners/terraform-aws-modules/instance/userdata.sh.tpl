#!/bin/bash
set -euxo pipefail

apt-get update -y

HOSTGROUP="${hostgroup}"
PORT="${port}"
ENVIRONMENT="${environment}"

echo -e "$HOSTGROUP\n$PORT\n$ENVIRONMENT"