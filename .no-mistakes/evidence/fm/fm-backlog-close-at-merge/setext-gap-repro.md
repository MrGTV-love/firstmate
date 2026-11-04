# Setext underline gap in the HTML-comment scan (live, lab Gitea 1.27.3, PR 34)

Body of the merged PR (4 lines):

    Intro <!-- a
    ===
    Closes-backlog-item: c20-real
    -->

CommonMark: line 1 + `===` is a setext heading, which ends the paragraph. The
unclosed `<!--` in it is plain text. Lines 3-4 are a new paragraph, so GitHub,
Gitea and Forgejo all show `Closes-backlog-item: c20-real` on the page.

bin/fm-pr-closes-lib.sh: the mid-line scan's stop set (stop_re) has no setext
`=` underline, so lines 2-4 are skipped as comment text.

Observed: bin/fm-pr-close-items.sh closed nothing, printed no line naming
c20-real (not closed, malformed or mentioned), and exited 0.
Expected: c20-real closes, as it does when `===` is replaced by `---`, `## H`,
`> q`, `- x` or `1. x` (cases c5-c9 in comment-scanner-matrix.txt, all PASS).
