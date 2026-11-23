#!/usr/bin/env bash
# devcontainer の initializeCommand から実行される、ホスト側の事前準備スクリプト。
# バインドマウント対象のファイルが未作成だとDockerが空ディレクトリを生成してしまい
# マウントが壊れるため、ここで事前にファイルとして用意する（過去に誤ってディレクトリ化
# されている場合はrmdirで復旧する）。
set -euo pipefail

h="$HOME"

ensure_file() {
	local path="$1"
	if [ -d "$path" ]; then
		rmdir "$path"
	fi
	[ -e "$path" ] || touch "$path"
}

ensure_file "$h/.claude.json"
ensure_file "$h/.gitconfig"

# ディレクトリ型のマウント元も、未作成だと --mount 形式では起動失敗するため事前に作成する。
mkdir -p "$h/.claude" "$h/.config/git" "$h/.config/gh"

mkdir -p "$h/.ssh"
chmod 700 "$h/.ssh"
ensure_file "$h/.ssh/known_hosts"

# SSH秘密鍵はコンテナに直接渡さず、ホストのssh-agentソケットのみをエージェントフォワーディングで共有する。
# mountsのsourceは常にこの固定パスを指すため、SSH_AUTH_SOCKが無効な場合でもマウント自体は成功させ、
# 空ファイルを置いてSSH転送なしで起動を継続できるようにする。
link="$h/.ssh/devcontainer-agent.sock"
tmp_link="$link.tmp.$$"
trap 'rm -f "$tmp_link"' EXIT
rm -f "$tmp_link"

if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] && ln -s "$SSH_AUTH_SOCK" "$tmp_link" 2>/dev/null; then
	:
else
	rm -f "$tmp_link"
	touch "$tmp_link"
	echo "devcontainer警告: SSH_AUTH_SOCK が未設定か無効です。ホストで ssh-agent を起動し ssh-add するとSSH経由のgit操作が可能になります（今回はSSH転送なしで起動します）" >&2
fi

# $linkが誤ってディレクトリ化されている場合、mvは検知せずディレクトリ内へ退避してしまうため、
# ensure_fileと同様に事前にrmdirで復旧を試みる（空でなければfail-fastする）。
if [ -d "$link" ]; then
	rmdir "$link"
fi

# 差し替え中に古いsocket/空ファイルが参照される隙をなくすため、mvで一気に置き換える。
mv -f "$tmp_link" "$link"
