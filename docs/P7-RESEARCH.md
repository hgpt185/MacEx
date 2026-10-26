# P7 research preview — local text and image similarity

Date: 2026-10-26. Version: 0.7.0. This completes the roadmap’s optional research prototype, not a general relevance/energy certification. Ordinary search and P6 OCR remain independently usable. Both experiments default off and require separate explicit consent for each app session.

## Evaluated choices

| Component | Behavior and availability | Model distribution | Decision |
|---|---|---|---|
| macOS Natural Language sentence embedding | Related-text ranking of selected-root text/OCR transcripts; returns unavailable when an installed language model cannot be obtained | No model artifact bundled or downloaded by MacEx; installed Apple OS component, not MIT-licensed model weights | Ship opt-in research tab with literal-search fallback |
| Vision image feature prints | Image-to-image distance from one explicitly chosen reference to indexed images | No external weights or download API; installed Apple OS component | Ship separate opt-in image-similarity research tab |
| External text/image shared embedding | Would require selecting, licensing, distributing/downloading and profiling specific model weights | No candidate was downloaded or redistributed | Not assumed; text-to-image natural-language search is not implemented or advertised |

The app code is MIT. Apple frameworks/models remain system components governed by their own distribution; MacEx does not relicense or redistribute their weights. App model-download size is **0 bytes**. The installed OS model’s on-disk size and licensing are not presented as an independently audited open-weight model package. There is no paid account, API key, telemetry or cloud provider.

Primary API references: [Apple sentence embeddings](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:)), [Vision feature-print requests](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest), and [feature-print distance](https://developer.apple.com/documentation/vision/vnfeatureprintobservation/computedistance(_:to:)). Smaller image distances indicate greater similarity. No similarity threshold establishes duplicate files; cleanup continues to require hashes and byte comparison.

## Measured evidence

Synthetic fixtures ran on Apple silicon/macOS 27.0.1. All values are observations from this machine, not cross-platform promises. The offline test profile denied network sockets to the test process and its children. Apple system services outside that process boundary were not packet-audited.

A billing query (“a customer bill that needs to be paid”) ranked three synthetic texts in the expected order: invoice/payment, annual budget, dog/park. The 512-dimensional sentence embedding produced cosine scores **0.5221, 0.3385, -0.0078**. One complete-suite observation took **0.061 s** including lookup; process CPU delta was **0.332 s**, and process lifetime peak RSS at that point was **127 MiB**. CPU/RSS include concurrent tests and are not exclusive model costs. This is one successful relevance fixture, not a statistically useful accuracy benchmark. Model revision and behavior can vary with OS/language.

Image fixtures compared an invoice image to its identical copy and an unrelated generated colored shape. The copy ranked first with distance **0.0**, followed by the unrelated shape at **1.1955**. An offline observation took **0.063 s**, process CPU delta **0.100 s**, and process lifetime peak RSS **83 MiB** at measurement. Native QA also returned the copied app-icon fixture from an explicit reference in **0.08 s**, with process lifetime peak RSS **170 MiB** after earlier UI/OCR work.

Hardware joules and battery drain were **not measured**. CPU time is only an energy-related proxy, not an energy measurement. No efficiency or battery-life claim is made. General accuracy, semantic similarity under realistic corpus changes, OS/language coverage and long-running energy/RAM profiling remain research work. The controls and documentation keep these experiments optional and visibly labeled.

## Bounds, consent and deletion

- Related text ranks at most the first 1,000 scoped index records, retaining at most 8 MiB of candidate text and 4,096 characters per document. It checks cancellation/time between embeddings, stops after 30 seconds and returns at most 50 results. An unavailable system model reports an actionable error rather than requesting a download.
- Image similarity considers at most 100 images from that bounded candidate set, uses first-frame thumbnails at 512 px, rejects nonregular/link paths and sources over 64 MiB or 50 megapixels, checks changes around bounded reads, stops between requests after 30 seconds and returns at most 50 results. One framework call has no hard deadline guarantee.
- Indexed candidates are constrained to the displayed local scope and rechecked for live file identities. The reference is one explicitly chosen local file, not a newly scanned root. Ranking runs on a utility worker.
- Vectors and image feature-print observations exist only during a query. No vector file/database is persisted. Clear Index removes the P6 text/metadata copies and empties displayed results. Root removal deletes that root’s records. Source files are unchanged. OS-managed caches, APFS snapshots and backups are outside the app’s erasure guarantee.
- Native relaunch checks confirmed session consent returns to off and saved roots remain idle. Consent rejection, unavailable language, cancellation, cosine edge cases, image ranking and no source mutation are tested.

The research verdict is to keep installed-framework text and image similarity as optional previews. Do not promote them to default search, verified duplicates, text-to-image semantics or an advertised general AI accuracy level on this evidence.
