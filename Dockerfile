FROM node:24-trixie-slim

# Dockerfile内のRUNをbash+pipefail付きで実行し、`curl | bash`のようなパイプ処理で
# 前段コマンドの失敗が握りつぶされないようにする
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Define build arguments for user customization
ARG USERNAME=node
# docker-init.sh実行時（コンテナ起動時）にも同じユーザー名を参照できるよう、
# ビルド時のARGをENVとして引き継ぐ。docker-init.sh側でハードコードすると
# USERNAMEをデフォルト値(node)以外にビルドした場合にsudoers(user=$USERNAME固定)と
# 実行時のsocatコマンドのuser指定が食い違い、sudoが拒否してしまうため
ENV DEVCONTAINER_USERNAME=$USERNAME

# Install sudo, minimal required development tools, GitHub CLI (gh), and
# Docker CLI (docker-outside-of-docker; ホストのDocker daemonをそのまま使うため、
# daemon本体は入れずCLI/buildx/composeプラグインのみを導入する)。
# python3/python3-venv/python3-pipはベースイメージ(node:24-trixie-slim)に含まれて
# いないため、devcontainer内でpython3を利用可能にする目的で追加する。
# Debian trixieのpipはデフォルトでPEP 668(externally-managed-environment)が有効で
# システム領域への直接installを拒否するため、python3-venvで作成した仮想環境経由での
# 利用を前提とする。
# 鍵取得・リポジトリ登録・インストールを1つのRUNにまとめ、apt listsの
# ダウンロード分がレイヤーごとに積み上がらないようにする。
# gnupgは鍵取得後にのみ必要なため、最後にpurgeして最終イメージから除去する。
# DEBIAN_FRONTEND=noninteractiveはこのRUN内(ビルド時)限定で有効にし、
# 最終イメージのENVには残さない(対話利用時にdebconfの挙動を変えないため)。
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update && apt-get install -y --no-install-recommends \
    sudo \
    ca-certificates \
    curl \
    gnupg \
    socat \
    procps \
    git \
    python3 \
    python3-venv \
    python3-pip \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    gh \
    docker-ce-cli \
    docker-buildx-plugin \
    docker-compose-plugin \
    && apt-get purge -y gnupg \
    && rm -rf /var/lib/apt/lists/*

# /bin/shをbashへのシンボリックリンクに変更する。DockerのSHELL命令は各RUNの
# 起動コマンドを直接指定するため本来は不要だが、コンテナ実行時（ビルド後）に
# #!/bin/shで始まるスクリプトがbash互換の挙動を前提にしているため維持する
RUN ln -sf /bin/bash /bin/sh

# corepack（pnpm/yarn等のパッケージマネージャー起動シム）を有効化する。
# Node 24ではcorepackは同梱されているが既定で無効なうえ、シム作成先の
# /usr/local/bin はroot所有のため、USER切り替え後に$USERNAMEが実行すると
# EACCESで失敗する。root権限があるこの時点で有効化しておくことで、
# 各プロジェクトのpackage.json記載のpackageManager（例: pnpm@11.7.0）に
# 従ったバージョンが$USERNAMEからも利用可能になる
RUN corepack enable

# ホストのDocker socketのGIDに合わせるためのdockerグループを作成し、$USERNAMEを所属させる
RUN groupadd --system docker \
    && usermod -aG docker "$USERNAME"

# dockerグループのGIDをホストDocker socketのGIDへ合わせる専用ラッパー。
# sudoers側でgroupmodへ可変のGID値を直接渡すワイルドカード許可(--gid [0-9]*)にすると、
# sudoersのワイルドカードが単語をまたいでマッチするため`-o`等のフラグを注入され
# GID 0(root)等の特権グループとの衝突を許してしまう。そのため引数をラッパー内で
# 厳格に検証してからgroupmodへ固定引数のみ渡す構成にしている
COPY docker-gid-fix.sh /usr/local/bin/docker-gid-fix.sh
RUN chmod +x /usr/local/bin/docker-gid-fix.sh

# コンテナ起動時にホスト側Docker socket(/var/run/docker-host.sock)のGIDへdockerグループを合わせる
# entrypoint。GIDがrootや既存グループと衝突する場合はsocatでsocketをプロキシする
COPY docker-init.sh /usr/local/bin/docker-init.sh
RUN chmod +x /usr/local/bin/docker-init.sh

# docker-init.sh がGID調整（docker-gid-fix.sh/socat等）にsudoを要求するため、$USERNAMEへ
# docker-init.shが実際に呼び出すコマンドラインのみに限定したパスワードなしsudo権限を付与する。
# コマンド名だけの許可（NOPASSWD:ALLに近い）だとsocat/tee/rm/ln等はGTFOBinsパターンで
# 任意ファイル書き込みや任意コマンド実行に転用できるため、引数まで固定する。
# docker-gid-fix.shのみ引数(GID値)を渡す必要があるため、sudoers側では引数指定を省略し
# （＝どんな引数でも許可）、スクリプト内部で引数を検証する構成にしている。
# この設計は/usr/local/binおよびdocker-gid-fix.sh自体が$USERNAMEから書き込み不可
# （root所有・非rootは書き込めないパーミッション）であることに依存する。
# 将来/usr/localの権限を緩める変更を行う場合は、このsudoers設計を見直すこと
# コマンドパスはビルド時にcommand -vで解決し、環境間の差異を吸収する。
# visudoで文法検証し、記述誤りがあればビルド自体を失敗させる
RUN GIDFIX_BIN="/usr/local/bin/docker-gid-fix.sh" \
    && MKDIR_BIN="$(command -v mkdir)" \
    && LN_BIN="$(command -v ln)" \
    && RM_BIN="$(command -v rm)" \
    && SOCAT_BIN="$(command -v socat)" \
    && TEE_BIN="$(command -v tee)" \
    && SUDOERS_FILE="/etc/sudoers.d/$USERNAME" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $GIDFIX_BIN" > "$SUDOERS_FILE" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $MKDIR_BIN -p /run/devcontainer-docker-proxy" >> "$SUDOERS_FILE" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $LN_BIN -s /var/run/docker-host.sock /var/run/docker.sock" >> "$SUDOERS_FILE" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $RM_BIN -f /var/run/docker.sock" >> "$SUDOERS_FILE" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $SOCAT_BIN UNIX-LISTEN\:/var/run/docker.sock\,fork\,mode\=660\,user\=$USERNAME\,group\=docker\,backlog\=128 UNIX-CONNECT\:/var/run/docker-host.sock" >> "$SUDOERS_FILE" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $TEE_BIN -a /run/devcontainer-docker-proxy/socat.log" >> "$SUDOERS_FILE" \
    && echo "$USERNAME ALL=(root) NOPASSWD: $TEE_BIN /run/devcontainer-docker-proxy/socat.pid" >> "$SUDOERS_FILE" \
    && chmod 0440 "$SUDOERS_FILE" \
    && visudo -cf "$SUDOERS_FILE"

# Playwright MCP（.mcp.json）が使うheadless Chromiumが依存するOSパッケージのインストール。
# apt権限が必要なためUSER切り替え前(root)で実行する。
# playwright本体のバージョンは.mcp.jsonの@playwright/mcpが依存するバージョンと一致させる。
# alpha版タグを固定利用しているため、@playwright/mcp側のバージョン更新時は追随漏れに注意する
RUN npx -y playwright@1.62.0-alpha-1783623505000 install-deps chromium

# Set the active user for subsequent steps and container execution
USER $USERNAME

RUN mkdir ~/.claude \
    && mkdir ~/.config \
    && mkdir ~/.ssh

RUN echo 'export PS1="\[\e[0;32m\]\u@\h\[\e[0;30m\]:\[\e[0;34m\]\W\[\e[0;30m\]\$ "' >> ~/.bashrc

# Claude Codeのインストール。SHELLでpipefailを有効にしているため、
# curlが失敗した場合はbashに空入力が渡って正常終了することなく、RUN自体が失敗する
RUN curl -fsSL https://claude.ai/install.sh | bash

# Playwright MCP（.mcp.json）が使うheadless Chromium本体のインストール（OSパッケージは導入済み）。
# playwright本体のバージョンは.mcp.jsonの@playwright/mcpが依存するバージョンと一致させる
RUN npx -y playwright@1.62.0-alpha-1783623505000 install chromium

# docker-init.shをENTRYPOINTとして実行し、コンテナ起動のたびにdocker socketの
# セットアップを行う。CMDはdevcontainerを起動状態に維持するための待機コマンド
ENTRYPOINT ["/usr/local/bin/docker-init.sh"]
CMD ["sleep", "infinity"]
