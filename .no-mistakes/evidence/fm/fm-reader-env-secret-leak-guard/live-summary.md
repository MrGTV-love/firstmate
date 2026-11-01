# Live worker environment probes (names only; fake sentinels only)

Each row is a real bin/fm-spawn.sh scout launch in a disposable fm-lab home on a private tmux socket, with fake credentials in the tmux server env.
The probe writes names and booleans only. GIT_CONFIG_KEY_n are non-secret and omitted.

| case | confinement | channels probed | credential-shaped names seen (any channel) | fake value in env dump | FM_TASK_ID ok | TERM | JAVA_HOME kept | PYTHONPATH dropped | real startup files (open-only) |
|---|---|---|---|---|---|---|---|---|---|
| HEAD claude | seatbelt-v1 | child_bash,child_sh,child_zsh_f,env,login_interactive_bash,login_interactive_zsh,python_os_environ | CLAUDE_CODE_MESSAGING_TOKEN | False | True | True | True | True | denied/missing |
| HEAD codex | unconfined-macos-codex | child_bash,child_sh,child_zsh_f,env,python_os_environ | - | False | True | True | True | True | missing/opened |
| HEAD control-unbounded-pane | None | child_bash,child_sh,child_zsh_f,env,python_os_environ | ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN DEEPSEEK_API_KEY FM_TEST_FAKE_API_KEY GEMINI_API_KEY LINEAR_API_KEY OPENAI_API_KEY TAC_HMAC_KEY VERCEL_TOKEN _SECRETS_LOADED | True | False | True | True | False | missing/opened |
| HEAD dsh | unconfined-macos-dsh | child_bash,child_sh,child_zsh_f,env,python_os_environ | - | False | True | True | True | True | missing/opened |
| HEAD omp-dotenv | seatbelt-v1 | child_bash,child_sh,child_zsh_f,env,python_os_environ | FM_TEST_FAKE_AGENT_DOTENV_KEY FM_TEST_FAKE_HOME_DOTENV_KEY GEMINI_API_KEY | True | True | True | True | True | denied/missing |
| HEAD omp-nodotenv | seatbelt-v1 | child_bash,child_sh,child_zsh_f,env,python_os_environ | - | False | True | True | True | True | denied/missing |
| HEAD omp | seatbelt-v1 | child_bash,child_sh,child_zsh_f,env,login_interactive_bash,login_interactive_zsh,python_os_environ | GEMINI_API_KEY | False | True | True | True | True | denied/missing |
| HEAD raw-allowlist | unconfined-macos-python3 | child_bash,child_sh,child_zsh_f,env,python_os_environ | FM_TEST_FAKE_API_KEY | True | True | True | False | True | missing/opened |
| HEAD raw | unconfined-macos-python3 | child_bash,child_sh,child_zsh_f,env,python_os_environ | - | False | True | True | True | True | missing/opened |
| BASE control-unbounded-pane | None | child_bash,child_sh,child_zsh_f,env,python_os_environ | ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN FM_TEST_FAKE_API_KEY GEMINI_API_KEY LINEAR_API_KEY OPENAI_API_KEY TAC_HMAC_KEY VERCEL_TOKEN _SECRETS_LOADED | True | False | True | True | False | missing/opened |
| BASE dsh | unconfined-macos-dsh | child_bash,child_sh,child_zsh_f,env,python_os_environ | - | False | True | True | True | False | missing/opened |
| BASE omp-nodotenv | seatbelt-v1 | child_bash,child_sh,child_zsh_f,env,python_os_environ | ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN FM_TEST_FAKE_API_KEY GEMINI_API_KEY LINEAR_API_KEY OPENAI_API_KEY TAC_HMAC_KEY VERCEL_TOKEN _SECRETS_LOADED | True | True | True | True | False | missing/opened |
| BASE raw | unconfined-macos-python3 | child_bash,child_sh,child_zsh_f,env,python_os_environ | ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN FM_TEST_FAKE_API_KEY GEMINI_API_KEY LINEAR_API_KEY OPENAI_API_KEY TAC_HMAC_KEY VERCEL_TOKEN _SECRETS_LOADED | True | True | True | True | False | missing/opened |
