# Folder UI correction

The user's screenshot identifies a flat rounded category card with a detached pill masquerading as a folder tab. Replace it with a connected tab/back, overlapping front pocket and actual rectangular file previews; place the category title and count/storage beneath the folder. Remove the decorative ellipsis that has no menu action.

Use the existing six category colors and support System/Light/Dark plus the independent Playful preference. Keep whole-tile activation, in-window navigation, actual catalog counts and local-only thumbnail policies. Empty categories show no invented previews. Labels must fit narrow windows and large counts.

Audit found two related defects: fixed 24-point placeholder padding makes small thumbnails invisible, and browser folders use flat tinted symbols instead of native folder artwork. Correct these consistently in grid and list views. Cleanup/source utilities should remain recognizable as actions, with consistent typography and truncation.

Implementation choice: a reusable SwiftUI folder illustration with a generic preview slot, integrated into the existing category buttons; native AppKit folder images for actual filesystem folders. This follows the explicit request rather than introducing a new application flow or a raster asset dependency. No personal file operations or automatic cleanup are authorized by this UI task.

User steering during implementation: use the exact supplied `Joyful Finder-Style Smiley Icon.png` as the new app logo. Keep its original bytes in Resources/AppIcon.png; normalize only generated icon padding to retain the full-size Dock treatment. The app header should also use the unframed artwork.
