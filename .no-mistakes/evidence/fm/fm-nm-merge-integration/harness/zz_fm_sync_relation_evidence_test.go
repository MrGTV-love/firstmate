package branchsync

// Evidence harness for firstmate branch fm/fm-nm-merge-integration, phase 2.
// Injected with `go test -overlay`; no no-mistakes source file is changed.
// Feeds each phase-1 repository to the real sync relation classifier
// (classifyRelation, live=true) with local head = the worker's submitted head
// and pushed = the pipeline's published head, exactly the `axi sync --check`
// decision that returned diverged / blocked_diverged on PRs 283 and 286.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type fmEvidenceCase struct {
	Name      string `json:"name"`
	Strategy  string `json:"strategy"`
	Dir       string `json:"dir"`
	Base      string `json:"base"`
	Submitted string `json:"submitted"`
	Published string `json:"published"`
}

func TestFMEvidence_SyncRelation(t *testing.T) {
	out := os.Getenv("FM_EVID_OUT")
	if out == "" {
		t.Skip("FM_EVID_OUT not set")
	}
	b, err := os.ReadFile(filepath.Join(out, "cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []fmEvidenceCase
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	got := map[string]State{}
	for _, c := range cases {
		s := &Service{WorkDir: c.Dir}
		st := State{}
		st.Local.Head = c.Submitted
		st.Pipeline.SubmittedHead = c.Submitted
		s.classifyRelation(context.Background(), &st, c.Published, c.Base, true)
		code := ""
		if st.NextAction != nil {
			code = st.NextAction.Code
		}
		t.Logf("SYNC %s (strategy=%s): state=%s relation=%s safety=%s next_action=%s", c.Name, c.Strategy, st.State, st.Relation, st.Safety, code)
		got[c.Name] = st
	}
	if st := got["control-base-config"]; st.Safety != "blocked_diverged" {
		t.Errorf("control did not reproduce the stuck state: %+v", st)
	}
	if st := got["candidate-branch-config"]; st.Safety != SafetySafeFastForward || st.Relation != RelationBehind || st.NextAction == nil || st.NextAction.Code != "sync" {
		t.Errorf("candidate is not an ordinary fast-forward sync: %+v", st)
	}
}
