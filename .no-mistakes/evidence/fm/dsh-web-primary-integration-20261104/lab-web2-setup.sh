#!/usr/bin/env bash
# Disposable native DSH Web lab. The lab home is the server's default workspace.
set -eu
D=$(mktemp -d "$HOME/tmp/fm-labweb.XXXXXX")
FM_HOME=$(bin/fm-lab-home.sh create "$D/deepseek-harness-default-workspace")
TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$FM_HOME")
git init -q "$FM_HOME"; printf 'lab primary fixture\n' > "$FM_HOME/AGENTS.md"; mkdir -p "$FM_HOME/bin"
R=$D/runtime; mkdir -p "$R/home" "$R/dsh/profiles/web"; ln -s "$R/dsh" "$R/home/.dsh"
cp ~/.dsh/profiles/web/package.json ~/.dsh/profiles/web/pnpm-workspace.yaml "$R/dsh/profiles/web/"
printf '[]\n' > "$R/dsh/profiles/web/cordis.yml"; printf '[]\n' > "$R/dsh/profiles/web/cordis.patch.yml"
cp ~/.dsh/.credentials.yaml "$R/dsh/.credentials.yaml"; chmod 600 "$R/dsh/.credentials.yaml"
cat > "$R/base.yml" <<YML
[{"id":"agent-default-model","config":{"provider":"deepseek-official","model":"deepseek-v4-flash","reasoningEffort":"low"}},
 {"id":"llm-deepseek","config":{"apiKeyEnv":"DEEPSEEK_API_KEY","models":[{"id":"deepseek-v4-flash"}]}},
 {"id":"workspace-controller","config":{"documentsDirectory":"$D"}}]
YML
cat > "$R/boot.sh" <<B
#!/usr/bin/env bash
cd "$FM_HOME"
export HOME=$R/home DSH_HOME=$R/dsh
dsh --profile web --patch $R/base.yml "\\\$@" --no-open --host 127.0.0.1 --port 0 2>&1 | tee -a $R/server.log
echo "server exited rc=\\\${PIPESTATUS[0]}" | tee -a $R/server.log
sleep 900
B
chmod +x "$R/boot.sh"
printf 'D=%s\nFM_HOME=%s\nTMUX_TMPDIR=%s\nR=%s\n' "$D" "$FM_HOME" "$TMUX_TMPDIR" "$R" | tee /tmp/fm-lab-web2-01M6K
echo "teardown: $PWD/bin/fm-lab-home.sh teardown $FM_HOME && rm -rf $D"
