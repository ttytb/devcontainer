# devcontainer

Visual Studio Code Dev Container 用のカスタムイメージです。Node.js 開発環境に GitHub CLI・Docker CLI（docker-outside-of-docker）・Playwright・Claude Code をプリインストールしています。

## 含まれるツール

- Node.js 24（`node:24-trixie-slim` ベース）
- GitHub CLI（`gh`）
- Docker CLI / Buildx / Compose プラグイン（docker-outside-of-docker構成。デーモン本体は含まずCLIのみ）
- Playwright（Chromium、`.mcp.json` の Playwright MCP 用）
- Claude Code

## イメージの利用方法

`.devcontainer/devcontainer.json` から GitHub Container Registry (GHCR) のイメージを参照できます。

```json
{
  "image": "ghcr.io/ttytb/devcontainer:latest"
}
```

## イメージのビルド・公開

`v*.*.*` 形式のタグ（例: `v1.0.0`）を push すると、GitHub Actions（`.github/workflows/docker-publish.yml`）が自動的にイメージをビルドし、`ghcr.io/ttytb/devcontainer` へ公開します。イメージタグは Git タグから `v` プレフィックスを除いた `:1.0.0`・`:1.0`・`:latest` になります（`v1.0.0-beta.1` のようなプレリリースタグでは `:1.0.0-beta.1` のみが付与され、`:1.0`・`:latest` は更新されません）。

```sh
git tag v1.0.0
git push origin v1.0.0
```

`main` ブランチへの通常の push ではビルド・公開は行われません。プルリクエストでは `Dockerfile`・`docker-init.sh`・`docker-gid-fix.sh`・`.github/workflows/docker-publish.yml` のいずれかに変更があった場合にビルド検証のみ行い、push はしません。

ローカルでビルドする場合:

```sh
docker build -t devcontainer .
```

## docker-outside-of-docker について

ホスト側の Docker socket を `/var/run/docker-host.sock` としてコンテナにバインドマウントする運用を前提としています（マウント自体は `devcontainer.json` や `docker run -v` 側で行います）。コンテナ起動時、`ENTRYPOINT` として実行される `docker-init.sh` がそのマウント済み socket の GID をコンテナ内の `docker` グループへ反映（GID 競合時は socat によるプロキシ）し、`/var/run/docker.sock` として使えるようにします。これによりコンテナ内のプロセスはホストの Docker デーモンを直接操作できるため、コンテナ内で実行するコードはホストに対して高い権限を持つ点に注意してください。
