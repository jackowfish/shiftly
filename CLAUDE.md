# Vale (prose and comment lint)

Config comes from `~/.vale.ini` with styles in `~/.claude/vale/styles/`; this repository has no local Vale config. Swift and Python are comment-aware formats, so code comments get linted and string literals do not.

- Lint everything written or edited before committing:
  `vale README.md Package.swift Sources tools/checks tools/render-calibration tools/gaze_eval.py`
- Fix every error. Treat warnings as defects unless the flagged text is genuinely right. The two recurring keeps in this repo: `Tropes.Tricolon` on factual three-item enumerations, and the first-person voice in the README (`Google.FirstPerson`, `Google.We`).
- Common fixes: `Tropes.EmDash` wants a plain ` - ` dash; `STE.Contractions` wants the expansion, so write `cannot` and `do not`; `Tropes.BannedPhrases` wants a direct rewording, and `instead of` or `, not` are safe substitutes.
- The banned phrase list grows over time, so rerun Vale on the whole repo before a release; a file that was clean last month can flag today.
- Vale misses a phrase split across a comment line break. After a clean run, grep for the newest banned phrases across line boundaries.
- Real names that trip `Vale.Spelling` go in the vocab at `~/.claude/vale/styles/config/vocabularies/Porter/accept.txt` ("Shiftly" and "Cmd" are already there); do not reword them.
