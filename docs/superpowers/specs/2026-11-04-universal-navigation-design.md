# Universal Back and Forward

The user approved extending Finder-style Back/Forward arrows and Command-[ / Command-] across every MacEx page, including Home, categories, folders, and searches.

Use one session history owned by `LibraryModel`. Entries preserve the route, folder location, search phrase and edited filters, source filter, and folder search context. Opening folders directly must participate in the same history as sidebar and menu navigation. Back/Forward close transient previews and cleanup reviews, restore the destination, and never add another history entry. A new destination after going back clears Forward. Reopening the current destination must not add duplicates; typing within one search updates that destination without adding a step per keystroke.

Keep both toolbar arrows visible and disable them when unavailable. Menu actions and toolbar buttons use the same history. Keep existing SFTP session and its internal folder controls; returning to Connections must not reconnect or send credentials. History is bounded and kept for this session; existing workspace persistence remains compatible.

## Approaches

- Keep folder-only history: smallest change, but cannot return to Home, categories, or searches; rejected by the user's universal scope.
- Add a single library-level history with folder-navigation hooks: chosen because it covers existing entry points and preserves search context without rewriting the browser.

Work in the current checkout because the user's uncommitted UI changes are part of the requested app state. Preserve those edits. No merge, push, or release is part of this task.
