# Working on AC-tionFinder

- The user writes in Dutch: answer in Dutch. Code, comments, UI texts and docs are in English.
- Read `docs/SPEC.md` first: it holds the design, the replay format and the algorithms.
- The reference implementation is the Python program in the repository `Akiruo666/OvertakeFinder` (`acreplay.py`, `trackdata.py`, `overtakes.py`, `battles.py`, `lua_app/OvertakeFocus/`). Attach it read-only when a detail in the spec is unclear; do not change it from here.
- The app runs inside the game: keep every frame cheap and do heavy work in slices with a visible progress percentage.
- CSP API calls differ between versions: guard them with `pcall` and tell the user which CSP feature is missing.
- The app cannot be run in the cloud container; the user tests in the game. Say clearly what was tested (e.g. the replay reader against the Python reader on the test replay) and what was not.
