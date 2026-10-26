MacEx 0.7.0 completes local OCR and editable natural-language search filters, plus optional local text/image similarity research. P1–P5 browsing, reviewed duplicate cleanup and secure SFTP remain available.

- Explicit local folders, bounded Vision/PDF/text extraction and private SQLite FTS5. No scan starts at launch. Exclusions, OCR languages, per-file checkpoints, FSEvents/reconciliation, resource pauses, Resume and Clear Index are included.
- Phrases such as “large videos in Downloads” become visible editable filters. Prior-calendar-week dates respect local time zones. Date-added/screenshot metadata gaps are disclosed. Unsupported phrases ask for refinement.
- Separate session-only opt-ins for installed macOS related-text embeddings and image-to-image feature prints. No cloud, API key or model download. These are research experiments; no general accuracy or hardware-energy claim is made.
- MIT source, bundled SSH notices and rebuild pins, universal Intel/Apple silicon downloads for macOS 14+, SHA-256 checksums, and a GitHub build workflow. The app is ad-hoc signed with hardened runtime and is **not notarized**. No Apple Developer Program account is required.

Validation: 72 registered tests, 71 passed and one optional cross-volume fixture skipped; 14 local-search tests also passed with network sockets denied. Native fixtures verified folder consent, indexing/search, incremental changes/deletions, phrase translation, both experiments, pause/clear, and inactive roots/consent reset after relaunch. See the P6 verification and P7 research reports in the repository.

Preview limits: full Xcode UI-suite execution, Intel/macOS 14 runtime, comprehensive VoiceOver/Finder/provider/TCC checks, independent SSH security audit and sustained resource profiling remain unverified. OCR and semantic quality vary. Framework calls have no universal hard memory/deadline guarantee. Similarity is not duplicate proof or text-to-image search. No file-operation Undo is implemented.

Download only from this repository’s Releases page, verify checksums, then copy MacEx to Applications. Follow Apple’s per-app opening flow if macOS blocks this non-notarized preview; do not disable Gatekeeper globally. Source builds remain available.
