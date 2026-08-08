#!/usr/bin/env bash
# docker-outside-of-dockerのentrypoint。
# ホスト側Docker socket(/var/run/docker-host.sock)をコンテナ内の/var/run/docker.sockとして
# 使えるようにする。socketのGIDをdockerグループに反映できる場合はgroupmodで合わせ、
# GIDが競合する場合はsocatでsocketをプロキシしてnodeユーザーからアクセス可能にする。
set -euo pipefail

# DEVCONTAINER_USERNAMEはDockerfileのARG USERNAMEをビルド時に焼き込んだ値。
# sudoers側のsocat許可コマンドもビルド時の値で固定文字列として生成されるため、
# `docker run -e DEVCONTAINER_USERNAME=...`等で実行時にこの値を上書きすると、
# sudoersのコマンド文字列と一致しなくなりsudoが拒否する(socatプロキシが起動できず
# docker.sockが作られないままコンテナは起動してしまう)。実行時に上書きしないこと
USERNAME="${DEVCONTAINER_USERNAME:-node}"
SOURCE_SOCKET="/var/run/docker-host.sock"
TARGET_SOCKET="/var/run/docker.sock"
RUNTIME_DIR="/run/devcontainer-docker-proxy"
SOCAT_LOG="${RUNTIME_DIR}/socat.log"
SOCAT_PID="${RUNTIME_DIR}/socat.pid"

sudoIf() {
    if [ "$(id -u)" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

# バックグラウンド起動専用。sudoIfをそのまま`&`でバックグラウンド化すると、
# if分岐を経由するため`sudo "$@"`がexec最適化されずforkのまま実行され、
# `$!`は実プロセス(sudo/socat)ではなく分岐を実行しているサブシェル自身のPIDを
# 指してしまう(生存確認は偶然機能するが、そのPIDをkillしても実プロセスは
# 孤児化して生き残り、二重起動の原因になる)。execで確実にプロセスイメージを
# 置き換えることで、`$!`が実プロセスのPIDを指すようにする。
# 決してdocker-init.sh本体から同期的に(バックグラウンド化せず)呼ばないこと。
# execする関数のため、呼んだ時点でスクリプト自体がそのコマンドに置き換わり、
# 以降の行(末尾のexec "$@"含む)が一切実行されなくなる。
#
# 既知の制約: `sudo`はuse_pty設定の有無に関わらず、シグナル/終了コード転送のため
# 常に自身をmonitorプロセスとして残しコマンドを子プロセスとしてforkする実装であり、
# execveによる完全な自己置換はsudo自体では起こらない(execされるのはsudoまでで、
# sudo→socatはforkの関係のまま)。そのため記録されるPIDは「sudo監視プロセス」であり、
# 万一sudoプロセスだけが単独でkillされ子のsocatが生き残った場合は孤児化し、
# 次回起動時に新しいsocatが追加起動されてしまう(機能は継続するがプロセスリークになる)。
# devcontainerというコンテナのライフサイクル上、sudoと子socatが個別にkillされる状況は
# 通常発生しない(コンテナ停止/再起動は全プロセスへ道連れに作用する)ため許容している
sudoExecIf() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo "$@"
    else
        exec "$@"
    fi
}

log() {
    # ロギングは非致命的な処理として扱う。失敗してもset -eでコンテナ起動
    # （後続のexec "$@"到達）自体を止めないよう、ここでのエラーは握りつぶす
    sudoIf mkdir -p "${RUNTIME_DIR}" || true
    echo -e "[$(date)] $*" | sudoIf tee -a "${SOCAT_LOG}" > /dev/null || true
}

# バックグラウンド化したsocatが生きているか判定する。docker-init.shは`exec "$@"`で
# 最終的に別プロセス(sleep infinity等)に置き換わりwait(2)を呼ばないため、
# killされたsocatは回収されずゾンビ(Z状態)のまま残り続ける。`ps -p`はゾンビも
# 「存在する」と判定してしまい自己修復が機能しなくなるため、状態がZでないことも確認する。
# 根本原因(ゾンビの回収役が存在しない)自体は解消していないため、自己修復が繰り返し
# 走るとゾンビが積み上がる可能性があるが、コンテナ再起動でリセットされるため許容している。
# 非rootから他ユーザー(root)のプロセス状態を`ps`で参照できることに依存する
# (procの`hidepid`制限が将来かかる環境では常に空文字列＝死亡扱いになる点に注意)
is_process_alive() {
    local pid="$1"
    local stat
    stat="$(ps -o stat= -p "${pid}" 2>/dev/null)" || return 1
    case "${stat}" in
        Z*|"") return 1 ;;
        *) return 0 ;;
    esac
}

if [ -S "${SOURCE_SOCKET}" ]; then
    sudoIf mkdir -p "${RUNTIME_DIR}"

    DOCKER_GID="$(getent group docker | cut -d: -f3)"
    SOCKET_GID="$(stat -c '%g' "${SOURCE_SOCKET}")"

    if [ "${SOCKET_GID}" = "${DOCKER_GID}" ]; then
        # 既にGIDが一致しているためgroupmod不要。symlinkのみで済ませる
        if [ ! -e "${TARGET_SOCKET}" ]; then
            sudoIf ln -s "${SOURCE_SOCKET}" "${TARGET_SOCKET}"
        fi
    elif [ "${SOCKET_GID}" != "0" ] && ! getent group "${SOCKET_GID}" > /dev/null 2>&1; then
        sudoIf /usr/local/bin/docker-gid-fix.sh "${SOCKET_GID}"
        if [ ! -e "${TARGET_SOCKET}" ]; then
            sudoIf ln -s "${SOURCE_SOCKET}" "${TARGET_SOCKET}"
        fi
    else
        # TARGET_SOCKETが既にUNIXソケットとして存在していても、socatプロセス自体が
        # (OOMやコンテナ再起動等で)異常終了しstaleなソケットファイルだけ残っている
        # ケースがあるため、生死判定は`-S`ではなくPIDの生存確認のみで行う
        if [ ! -f "${SOCAT_PID}" ] || ! is_process_alive "$(cat "${SOCAT_PID}")"; then
            log "Proxying ${SOURCE_SOCKET} to ${TARGET_SOCKET} for ${USERNAME}"
            sudoIf rm -f "${TARGET_SOCKET}"
            # ログファイルはroot所有で作成されるため、一般ユーザーの`>>`直接リダイレクトでは
            # 書き込み権限エラーになる。プロセス置換(> >(...))でtee側もsudoIf経由(root)にしつつ、
            # teeはパイプの一部にならないため$!には影響しない。sudoExecIf(execで確実に
            # プロセスイメージを置き換える版)を使うことで、$!はバックグラウンド化した
            # socat(sudo経由時はsudo)自身のPIDを正しく指す。
            ( sudoExecIf socat UNIX-LISTEN:"${TARGET_SOCKET}",fork,mode=660,user="${USERNAME}",group=docker,backlog=128 UNIX-CONNECT:"${SOURCE_SOCKET}" ) > >(sudoIf tee -a "${SOCAT_LOG}") 2>&1 &
            echo "$!" | sudoIf tee "${SOCAT_PID}" > /dev/null
        fi
    fi
else
    log "SOURCE_SOCKET(${SOURCE_SOCKET}) が見つからないため、docker-outside-of-dockerのセットアップをスキップします"
fi

exec "$@"
