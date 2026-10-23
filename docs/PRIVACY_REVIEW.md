# Privacy review - Beta 3

Reviewed the initial repository's full reachable history, tracked files and screenshot sources, PNG metadata, Beta 1 source/app release assets, and the Beta 2/3 feature source. The Beta 3 review also covered multi-peer clipboard/session lifecycles, master off/on behavior, token removal after publication and exact-origin redirect authorization. An independent read-only review also inspected the update, contacts, hotspot and window paths.

No confirmed credential, private account profile, personal network endpoint or live account screenshot was found in the reviewed material. The screenshots use the explicit synthetic profile in ScreenshotRenderer; SIP examples use invented identifiers and protocol domains. Public Samsung client identifiers and upstream license contacts are not secret account tokens.

The initial commit retains its author's configured email. That is public Git metadata if the repository is made public; no history rewrite or visibility change was performed. The repository remained private during this review.

Developer-only material, account files, captures, helpers and raw audit downloads remain outside tracked source and delivery archives. The eight current demo page renders carry an explicit bitmap label; the stale Beta 1 storage screenshot was removed. Demo renders do not persist their synthetic device preferences.

Updater trust and private-token storage are explained in SECURITY.md. This is a scoped review, not a guarantee that no vulnerability exists. Final compiled-artifact checks and delivery state are recorded in BETA_2.md and BETA_3.md.


## RC 1 scope

The new Buds exclusion policy reads CoreAudio output-process metadata only while automatic switching needs it. Process names and bundle identifiers are used in memory for exact system-service exclusion, with no taps, audio recording, history, uploads or polling. All eight page renders use fictional account/device state and a visible demo label. RC 1 artifact checks and remaining runtime acceptance are recorded in [RC_1.md](RC_1.md).


## v1.0 public release scope

Rechecked the current authored tree and all reachable history before public release, alongside retained audited Beta 1, Beta 3 and RC1 assets. High-confidence credential, private-key and user-home-path scans found no disclosure; prior live GitHub archive digests matched the retained audited copies. The final app/source archives receive a decoded review and private-baseline comparison before publication. Temporary token settings are removed; no token or live account profile is distributed. Hardware model/OS versions in the validation matrix are non-unique compatibility information. Git author metadata and upstream attributions remain part of the public repository.
