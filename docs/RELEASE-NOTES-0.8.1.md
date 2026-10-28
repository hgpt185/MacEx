MacEx 0.8.1 fixes library discovery, sidebar interaction and appearance in the single-window workflow.

- Existing images, screenshots, documents and installed apps are discovered from standard personal folders and application directories on ordinary launches. Saved custom folders and default-location exclusions are preserved; incomplete coverage is shown in Settings.
- Discovery waits for saved folders to load before reacting to startup file-change notifications, so an early refresh cannot omit custom locations.
- Categories, Duplicates and Similar Photos use the same real library catalog. Duplicate comparisons retain identity, hash and byte verification and require explicit review before Trash.
- The supplied red-and-cream smiling logo appears in the Dock, app bundle and sidebar.
- Sidebar icons, titles and counts align consistently. The entire padded row responds to clicks, including blank space.
- The top-bar appearance button switches Light/Dark immediately. Settings adds System/Light/Dark with persistence across launches; Playful colors remain independent.
- Quick Look thumbnail completions safely return to the main actor, preventing the executor crash found during relaunch and first duplicate scanning.
- Isolated QA profiles are visibly labeled and never automatically add real personal roots. Optional automation remains off by default, uses only explicitly added custom folders, and never runs from Refresh.

MIT licensed, universal for Apple silicon and Intel, macOS 14+, ad-hoc signed and **not notarized**. No Apple Developer Program membership is required. Files and previews stay inside the existing MacEx window.

Preview limits: Intel/macOS 14 runtime, broad VoiceOver/keyboard/high-contrast/reduced-motion audits, provider/network-volume/TCC-revocation checks, native drag interoperability, and sustained resource/energy profiling remain unverified. Universal binary validation does not establish runtime coverage on every supported Mac.

Keep custom content folders separate from MacEx's state directory. Watching the state directory can trigger refreshes that clear duplicate comparison results; standard discovery folders do not overlap the default state location.

Verification: 101 service/app tests passed with one optional cross-volume skip, 40 offline checks passed, and all six Xcode UI tests passed. CI builds both CPU architectures and verifies signing, Shortcuts metadata and package checksums.
