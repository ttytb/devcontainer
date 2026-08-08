#!/usr/bin/env bash
# dockerグループのGIDをホストDocker socketのGIDに合わせる専用ラッパー。
# sudoersでgroupmodへの引数を可変(GID値)にすると、ワイルドカードパターンが
# 単語をまたいでマッチするため`-o`等のフラグを注入されGID 0(root)やGID 42(shadow)
# へ変更されうる。ここで引数を厳格に検証してからgroupmodへ固定引数のみ渡す。
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: docker-gid-fix.sh <gid>" >&2
    exit 1
fi

GID="$1"

if ! [[ "${GID}" =~ ^[0-9]+$ ]]; then
    echo "Invalid GID: ${GID}" >&2
    exit 1
fi

if [ "${GID}" -eq 0 ]; then
    echo "Refusing to use GID 0 (root)" >&2
    exit 1
fi

EXISTING_GROUP="$(getent group "${GID}" | cut -d: -f1 || true)"
if [ -n "${EXISTING_GROUP}" ] && [ "${EXISTING_GROUP}" != "docker" ]; then
    echo "GID ${GID} is already used by group: ${EXISTING_GROUP}" >&2
    exit 1
fi

exec groupmod --gid "${GID}" docker
