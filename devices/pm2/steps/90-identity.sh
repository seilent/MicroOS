#!/usr/bin/env bash
set -euo pipefail

v=${MICROOS_VERSION:-}
[[ $v =~ ^[0-9]{8}\.[0-9a-z]+$ ]] || { echo "90-identity: MICROOS_VERSION '$v' is not YYYYMMDD.<id>" >&2; exit 1; }

cat > /usr/lib/os-release <<OS
NAME=MicroOS
ID=microos
ID_LIKE=fedora
VERSION_ID=44
PRETTY_NAME="MicroOS"
IMAGE_VERSION=$v
DEFAULT_HOSTNAME=microos
HOME_URL=https://github.com/seilent/MicroOS
OS

install -d /usr/lib/microos
printf 'IMAGE_VERSION=%s\n' "$v" > /usr/lib/microos/version

[[ $(readlink /etc/os-release) == ../usr/lib/os-release ]] || { echo "90-identity: /etc/os-release is not ../usr/lib/os-release" >&2; exit 1; }
