# Trading features between the branches

Two lines of Coastline are developed side by side in this repository:

| Branch | Line | Who changes it |
|---|---|---|
| `main` | C: control, fixture library, machine profiles | its own maintainer only |
| `xioaniumi` | K: line C plus the clamp kit workflow | its own maintainer only |

Neither branch is merged into the other. Each side reviews what the other did and takes the parts
it wants, one feature at a time. This file is the shared record of that: what was looked at, what
was taken, what was left out and why. [FEATURES.md](FEATURES.md) lists every feature with its files
and tests.

## Not ready to take: work in progress

Much of what `xioaniumi` gained on 2026-11-26 is work in progress: committed so it isn't lost, but
not working properly yet. **Please don't cherry-pick these until this section says they're ready.**

| Commits | What | State |
|---|---|---|
| `39ddcf9`, `acd7ab7` | K10: bit IDs, wear forecast, worn-bit feeds, Save tools | WIP |
| `c165c36` | K11: Tool Check plan | A plan only, no code |
| `7fd6e32` … `20221b0` | K12: sharp snapshots, exact readouts, mesh export (.3dm, 3MF, STEP), clean CAD (NURBS STEP and Rhino .3dm), the Sharpen button and its options panel | WIP |
| `3500987`, `69dc2ea` | Example projects regenerated for these changes | Follow the WIP above |
| `6d16914`, `557b1fe`, `20221b0` | Job strip: chapters as an accordion, open on the click, eased timing | WIP |
| `ae95210` | Floor finishing past drop-off edges (no 0.1 mm islands) | WIP |

Commits before 2026-11-26 (up to `047be59`) are unaffected.

## Rules

1. **Never push to the other branch**, and never rewrite history on your own once it's pushed
   (no force-push). The other side builds on it.
2. **One feature or fix per commit.** A commit is the unit the other side takes or skips. Keep
   refactors, formatting and features in separate commits.
3. **Say what it is in the first line**, the why in the body, and end the body with the tests run.
   Example: `Jog with the arrow keys in Machine Control`.
4. **Keep FEATURES.md current.** A new feature gets an entry (files, hooks, tests) in the same
   commit or the next one.
5. **Every commit builds and passes** `scripts/selftest.sh`, the MillCore self-tests and the
   engine's pytest. Safety limits are never weakened to make a test pass.

## Seeing what's new on the other side

On GitHub, the compare view shows commits and the full diff:

- what `xioaniumi` has that `main` doesn't: `compare/main...xioaniumi`
- what `main` has that `xioaniumi` doesn't: `compare/xioaniumi...main`

From a checkout (`origin` being this repository):

```bash
git fetch origin
git log --oneline --no-merges main..origin/xioaniumi      # on main: what line K added
git log --oneline --no-merges xioaniumi..origin/main      # on xioaniumi: what line C added
git cherry -v HEAD origin/<other-branch>                  # "+" not taken yet, "-" already here (same patch)
git show <commit>                                         # one commit in full
```

## Taking a feature

- **As it is:** `git cherry-pick -x <commit>`. The `-x` adds "(cherry picked from commit …)" to the
  message, so both sides can trace it. Resolve any conflict, run the tests, push to your own branch.
- **In part, or reworked:** port it by hand and end the commit message with
  `Ported from <branch> <commit>` (and what was left out).
- **Not taking it:** nothing to do in git; note it in the log below so it isn't reviewed again.

Then add a line to the log.

## Log

Newest first. "Reviewed up to" is the other branch's last commit looked at, so the next round
starts after it.

| Date (UTC) | Branch updated | From | Reviewed up to | Taken | Left out, and why |
|---|---|---|---|---|---|
| 2026-11-25 | `xioaniumi` | `main` | `2d78190` | `2d78190`: the universal clamp pair in the fixture library (with its STEP assembly), sizes in the chosen units, the steady probe message. The clamp kit's own stock options follow the units too | The same commit's Qt app files in `app/` (not on this branch) |
| 2026-11-21 | `xioaniumi` | `main` | `4c07c02` | From `b073b68` the Swift parts only: mill auto-connect retries (1, 2, 5 s), port diagnostics in the console, Arduino 2341:003E and boards without a serial number, M102/M106 in the built-in runner, `wsnap` automation | The Qt app in `app/`, the Windows release build and its packaging fixes (`833c6d0`, `741a2a2`, `6e150e5`, `4c07c02`): a separate app; this branch stays on the Swift app for now |
| 2026-11-14 | `xioaniumi` | `main` | `410a714` (v0.10) | Everything from v0.2 to v0.10: the branch starts from `main` at v0.10 | The removal in v0.6: the clamp kit workflow is kept, alongside the fixture library |
