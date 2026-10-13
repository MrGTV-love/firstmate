fm_launch_git_hooks() {
  fm_hooks=$1 fm_keep=$2 fm_count=${GIT_CONFIG_COUNT-0}
  fm_i=0 fm_out=0 fm_key= fm_value=
  case "$fm_count" in ''|*[!0-9]*) return 0 ;; esac
  while [ "$fm_i" -lt "$fm_count" ]; do
    eval "fm_key=\${GIT_CONFIG_KEY_$fm_i-} fm_value=\${GIT_CONFIG_VALUE_$fm_i-}"
    if [ "$fm_key" != core.hooksPath ] || [ "$fm_value" != "$fm_hooks" ]; then
      if [ "$fm_i" -ne "$fm_out" ]; then
        export "GIT_CONFIG_KEY_$fm_out=$fm_key" "GIT_CONFIG_VALUE_$fm_out=$fm_value"
      fi
      fm_out=$((fm_out + 1))
    fi
    fm_i=$((fm_i + 1))
  done
  fm_i=$fm_out
  while [ "$fm_i" -lt "$fm_count" ]; do
    unset "GIT_CONFIG_KEY_$fm_i" "GIT_CONFIG_VALUE_$fm_i"
    fm_i=$((fm_i + 1))
  done
  if [ "$fm_keep" = 0 ]; then
    export "GIT_CONFIG_KEY_$fm_out=core.hooksPath" "GIT_CONFIG_VALUE_$fm_out=$fm_hooks"
    fm_out=$((fm_out + 1))
  fi
  if [ "$fm_out" -eq 0 ]; then
    unset GIT_CONFIG_COUNT
  else
    export GIT_CONFIG_COUNT=$fm_out
  fi
}

fm_launch_git_hooks '/private/tmp/fm-lab.DKt9pt/state/fm-nohelp.git-hooks' 0; unset fm_hooks fm_keep fm_count fm_i fm_out fm_key fm_value; unset -f fm_launch_git_hooks; export COMPACT_ADVISER_DISABLE=1; [ "${FM_COMPACT_ADVISER_HOOKS-}" != 1 ] || unset CLAUDE_CODE_ENABLE_FUNCTION_HOOKS FM_COMPACT_ADVISER_HOOKS; export FM_TASK_INBOX='/private/tmp/fm-lab.DKt9pt/state/fm-nohelp.inbox'; env PI_EDIT_VARIANT=replace PI_CODING_AGENT_DIR='/tmp/fmlive.9rLnPC/agent' env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '/Users/charlesabrooker/.bun/bin/omp' --config '/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/.omp/fm-session-overlay.yml' --auto-approve --cwd '/tmp/fmlive.9rLnPC/wt-fm2' --config '/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/.omp/fm-worker-overlay.yml' --config '/tmp/fm-lab.DKt9pt/state/fm-nohelp.omp-fallback.yml' --no-title --config '/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/.omp/fm-no-helpers-overlay.yml' --no-extensions --no-skills --no-rules --tools read,bash,edit,write,grep,glob,todo,ask --model 'fixture/main' --thinking 'high' -e '/tmp/fm-lab.DKt9pt/state/fm-nohelp.omp-ext.ts' "$('/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50/bin/fm-operational-input.sh' encode launch-brief < '/tmp/fm-lab.DKt9pt/data/fm-nohelp/launch-brief.md')"
