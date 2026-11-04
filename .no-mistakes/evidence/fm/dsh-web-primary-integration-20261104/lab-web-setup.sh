#!/usr/bin/env bash
# Disposable native DSH Web server lab: isolated HOME/DSH_HOME inside a marked lab home.
set -eu
eval "$(bin/fm-lab-home.sh env)"
printf 'FM_HOME=%s\nTMUX_TMPDIR=%s\n' "$FM_HOME" "$TMUX_TMPDIR"
git init -q "$FM_HOME"
printf 'lab primary fixture\n' > "$FM_HOME/AGENTS.md"
mkdir -p "$FM_HOME/bin"
LAB=$FM_HOME/.lab-dsh-runtime
mkdir -p "$LAB/home" "$LAB/dsh/profiles/web"
ln -s "$LAB/dsh" "$LAB/home/.dsh"
cp ~/.dsh/profiles/web/package.json ~/.dsh/profiles/web/pnpm-workspace.yaml "$LAB/dsh/profiles/web/"
printf '[]\n' > "$LAB/dsh/profiles/web/cordis.yml"; printf '[]\n' > "$LAB/dsh/profiles/web/cordis.patch.yml"
cp ~/.dsh/.credentials.yaml "$LAB/dsh/.credentials.yaml"; chmod 600 "$LAB/dsh/.credentials.yaml"
cat > "$LAB/base.yml" <<YML
[{"id":"agent-default-model","config":{"provider":"deepseek-official","model":"deepseek-v4-flash","reasoningEffort":"low"}},
 {"id":"llm-deepseek","config":{"apiKeyEnv":"DEEPSEEK_API_KEY","models":[{"id":"deepseek-v4-flash"}]}}]
YML
echo "$FM_HOME" > /tmp/fm-lab-web-01M6K
