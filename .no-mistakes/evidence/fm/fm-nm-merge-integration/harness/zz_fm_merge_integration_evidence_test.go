package steps

// Evidence harness for firstmate branch fm/fm-nm-merge-integration.
// Injected with `go test -overlay` so no no-mistakes source file is changed.
// Phase 1: load the firstmate .no-mistakes.yaml through the real trusted-config
// path (LoadRepoFromBytes -> EffectiveRepoConfig -> MergeForRemote), then run
// the real RebaseStep with the resulting strategy over a moved main, add a
// pipeline fix-round commit that edits the submitted line again, and record
// submitted head S and published head P for phase 2 (branchsync classifier).

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/kunchenguid/no-mistakes/internal/config"
)

type fmEvidenceCase struct {
	Name          string   `json:"name"`
	Strategy      string   `json:"strategy"`
	Dir           string   `json:"dir"`
	Base          string   `json:"base"`
	Submitted     string   `json:"submitted"`
	Main          string   `json:"main"`
	Integrated    string   `json:"integrated"`
	IntegParents  []string `json:"integrated_parents"`
	Published     string   `json:"published"`
	SubmittedIsAn bool     `json:"submitted_is_ancestor_of_published"`
}

func fmResolveStrategy(t *testing.T, trustedYAML []byte, pushedYAML string) string {
	t.Helper()
	trusted, err := config.LoadRepoFromBytes(trustedYAML)
	if err != nil {
		t.Fatalf("trusted .no-mistakes.yaml failed to parse with the real loader: %v", err)
	}
	pushed, err := config.LoadRepoFromBytes([]byte(pushedYAML))
	if err != nil {
		t.Fatalf("pushed yaml parse: %v", err)
	}
	eff := config.EffectiveRepoConfig(pushed, trusted, trusted.AllowRepoCommands)
	global, err := config.LoadGlobalFromBytes([]byte("{}\n"))
	if err != nil {
		t.Fatalf("global: %v", err)
	}
	cfg := config.MergeForRemote(global, eff, "https://github.com/MrGTV-love/firstmate")
	return cfg.Rebase.Strategy
}

func fmGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return gitCmd(t, dir, args...)
}

func fmBuildAndIntegrate(t *testing.T, root, name, strategy string) fmEvidenceCase {
	t.Helper()
	upstream := filepath.Join(root, name+"-upstream.git")
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(upstream, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	fmGit(t, upstream, "init", "--bare")
	fmGit(t, dir, "init")
	fmGit(t, dir, "config", "user.name", "lab")
	fmGit(t, dir, "config", "user.email", "lab@example.invalid")
	fmGit(t, dir, "checkout", "-b", "main")
	fmGit(t, dir, "remote", "add", "origin", upstream)
	writeFixtureFile(t, dir, "shared.txt", "alpha\nbravo\ncharlie\ndelta\necho\n")
	fmGit(t, dir, "add", "-A")
	fmGit(t, dir, "commit", "-m", "base")
	base := fmGit(t, dir, "rev-parse", "HEAD")
	fmGit(t, dir, "push", "origin", "main")

	// Worker submits S: edits line 1.
	fmGit(t, dir, "checkout", "-b", "feature")
	writeFixtureFile(t, dir, "shared.txt", "alpha-worker\nbravo\ncharlie\ndelta\necho\n")
	fmGit(t, dir, "commit", "-am", "worker change")
	submitted := fmGit(t, dir, "rev-parse", "HEAD")

	// main moves under the run: edits line 5 of the same file (no conflict).
	fmGit(t, dir, "checkout", "main")
	writeFixtureFile(t, dir, "shared.txt", "alpha\nbravo\ncharlie\ndelta\necho-main\n")
	fmGit(t, dir, "commit", "-am", "main advance")
	mainSHA := fmGit(t, dir, "rev-parse", "HEAD")
	fmGit(t, dir, "push", "origin", "main")
	fmGit(t, dir, "checkout", "feature")

	f := mergeFixture{dir: dir, upstream: upstream, baseSHA: base, headSHA: submitted, mainSHA: mainSHA}
	sctx := f.context(t, &mockAgent{name: "test"}, "")
	sctx.Config.Rebase.Strategy = strategy
	outcome, err := (&RebaseStep{}).Execute(sctx)
	if err != nil {
		t.Fatalf("%s: RebaseStep: %v", name, err)
	}
	if outcome.NeedsApproval {
		t.Fatalf("%s: RebaseStep parked: %v", name, outcome.Findings)
	}
	integrated := fmGit(t, dir, "rev-parse", "HEAD")
	ps := parents(t, dir, integrated)

	// Pipeline fix round: edits the submitted line again in its own checkout.
	writeFixtureFile(t, dir, "shared.txt", strings.Replace(fmReadFile(t, filepath.Join(dir, "shared.txt")), "alpha-worker", "alpha-worker-fixed", 1))
	fmGit(t, dir, "commit", "-am", "pipeline fix round")
	published := fmGit(t, dir, "rev-parse", "HEAD")

	anc := gitOK(dir, "merge-base", "--is-ancestor", submitted, published)
	return fmEvidenceCase{Name: name, Strategy: strategy, Dir: dir, Base: base, Submitted: submitted, Main: mainSHA,
		Integrated: integrated, IntegParents: ps, Published: published, SubmittedIsAn: anc}
}

func fmReadFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func gitOK(dir string, args ...string) bool {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	return cmd.Run() == nil
}

func TestFMEvidence_MergeIntegration(t *testing.T) {
	out := os.Getenv("FM_EVID_OUT")
	if out == "" {
		t.Skip("FM_EVID_OUT not set")
	}
	branchYAML, err := os.ReadFile(os.Getenv("FM_EVID_BRANCH_YAML"))
	if err != nil {
		t.Fatal(err)
	}
	baseYAML, err := os.ReadFile(os.Getenv("FM_EVID_BASE_YAML"))
	if err != nil {
		t.Fatal(err)
	}
	hostilePushed := "rebase:\n  strategy: rebase\n"

	branchStrategy := fmResolveStrategy(t, branchYAML, hostilePushed)
	baseStrategy := fmResolveStrategy(t, baseYAML, "")
	t.Logf("CONFIG branch-trusted + pushed(strategy: rebase) -> effective rebase.strategy=%q", branchStrategy)
	t.Logf("CONFIG base-commit trusted (control) -> effective rebase.strategy=%q", baseStrategy)
	if branchStrategy != config.RebaseStrategyMerge {
		t.Fatalf("branch config resolves to %q, want merge", branchStrategy)
	}
	if baseStrategy != config.RebaseStrategyRebase {
		t.Fatalf("base config resolves to %q, want rebase (control)", baseStrategy)
	}

	// Adversarial: a typo strategy must fail closed in the real loader.
	typo := strings.Replace(string(branchYAML), "strategy: merge", "strategy: merges", 1)
	if _, err := config.LoadRepoFromBytes([]byte(typo)); err == nil {
		t.Fatalf("typo strategy was accepted")
	} else {
		t.Logf("ADVERSARIAL typo strategy: merges -> loader error: %v", err)
	}

	cases := []fmEvidenceCase{
		fmBuildAndIntegrate(t, out, "control-base-config", baseStrategy),
		fmBuildAndIntegrate(t, out, "candidate-branch-config", branchStrategy),
	}
	for _, c := range cases {
		t.Logf("CASE %s strategy=%s submitted=%s integrated=%s parents=%v published=%s submitted_is_ancestor=%v",
			c.Name, c.Strategy, c.Submitted[:8], c.Integrated[:8], c.IntegParents, c.Published[:8], c.SubmittedIsAn)
	}
	b, _ := json.MarshalIndent(cases, "", "  ")
	if err := os.WriteFile(filepath.Join(out, "cases.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}
