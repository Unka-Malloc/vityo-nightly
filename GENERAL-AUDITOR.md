# General-Auditor

CI uses `Unka-Malloc/General-Auditor@only` to check this repository's common and
repository-specific policy. It does not create or upload reports or source
evidence. Existing required status names and product checks are preserved.
Keyword matches are candidates for contextual review, not confirmed privacy
disclosures.

The retired `styio-audit` framework is private and archived. This repository has
no active dependency on its packages, clones or workflow.

## Local source evidence

Use a trusted General-Auditor checkout on `only`. Select its absolute directory
with `--audit-root` where supported, otherwise `GENERAL_AUDITOR_ROOT`, otherwise
repository-local `git config --local generalAuditor.root`. The selected directory
must contain `action_entry.py`. There is no PATH lookup or common-only fallback.

```sh
git config --local generalAuditor.root "$GENERAL_AUDITOR_ROOT"
python3 -I "$GENERAL_AUDITOR_ROOT/action_entry.py" scan \
  --policy-root "$GENERAL_AUDITOR_ROOT" --repository "Unka-Malloc/vityo-nightly" \
  --directory "$(git rev-parse --show-toplevel)" --scope staged
```

Use `--scope worktree` for tracked and nonignored untracked working files,
`--scope history` for commits reachable from HEAD, or `--scope range --base <commit>`
for outgoing commits. Nested product scripts scan their owning Git repository.
Local hooks and delivery wrappers use the same trusted root.

Raw matches, original source context and the self-contained HTML report are saved
only under the Git repository's `.general-auditor/local/` directory. This directory
is ignored by Git. Do not attach, publish or upload its contents. Ignore rules do
not remove files already tracked by Git; retain any existing user data privately
before explicitly untracking it. The terminal shows only status and counts.

Review candidates with the local Agent using `review-request --directory <repository>`
and record supported judgments with `review-complete --directory <repository>`.
A successful scanner exit is not contextual privacy approval. Original values
must stay in the private report files, never terminal output or CI artifacts.
