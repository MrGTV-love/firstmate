import sys
path, needs_line = sys.argv[1], sys.argv[2]
t = open(path).read()
t = t.replace("{TASK}", "List the tools this session offers and record them; change nothing else in the repository.")
t = t.replace("{FIRSTMATE_SPEC}", "Write the exact names of every tool available to you in this session, one per line, into the scout report. Do not call find, web_search or any outbound tool. Then report done.")
t = t.replace("{DOD_CAPABILITY}", "The scout report lists the session's tool names.")
t = t.replace("{DOD_MANDATORY_ITEMS}", "M1 Source: lab brief. Expected: report lists tool names. Verify: read report. Edge/negative: none. Evidence place: report. Authority: agent")
t = t.replace("{DOD_SUPPORTING_ITEMS}", "None.")
t = t.replace("{DOD_HARD_GATES}", "Never call an outbound tool.")
t = t.replace("{DOD_HONESTY_RULE}", "Report only names you observed.")
t = t.replace("### Out of scope\n\n", "### Out of scope\nNone.\n\n", 1)
if needs_line != "KEEP":
    t = t.replace("Egress needs: []", needs_line, 1)
open(path, "w").write(t)
