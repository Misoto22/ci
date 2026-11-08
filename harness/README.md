# Misoto Harness checkers

Every checker Misoto Harness has released, named by the sha256 of its bytes. The rules
workflow, `.github/workflows/harness-rules.yml`, fetches the file a governed repository pins in
its managed `.rulesync/checker.json`, and runs it only when the hash matches (Harness ADR 0004).

- **Owner.** Harness owns these files; they are copies of
  `src/misoto_harness/templates/project-harness-check.py` at each release. Do not edit one: a
  changed byte changes its hash, and every repository that pins the old hash would refuse it.
- **Append-only.** A file is never edited, renamed, or removed while any repository can still pin
  it. A release with a new checker adds one file here before the fleet sync runs.
- **Python, not YAML.** This repository otherwise ships YAML and shell; these files are served
  data that the rules job downloads, not code this repository runs.

Run the checker a repository pins, from that repository's root:

```bash
sha=$(python3 -c "import json;print(json.load(open('.rulesync/checker.json'))['sha256'])")
curl -fsSL "https://raw.githubusercontent.com/Misoto22/ci/main/harness/checkers/$sha.py" -o /tmp/harness-check.py
echo "$sha  /tmp/harness-check.py" | shasum -a 256 -c - && python3 /tmp/harness-check.py
```
