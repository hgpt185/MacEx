# MacEx videos

Remotion project for MacEx demo and marketing clips. Everything is React
components rendered frame by frame, so videos are versioned alongside the app.

## Requirements

- Node.js 20.19+, 22.13+ or 24+
- Google Chrome/Chromium (Remotion downloads its own headless shell if needed)

## Commands

Run from this `video/` folder:

```bash
npm install          # first time only
npm run studio       # open Remotion Studio for live preview
npm run render:intro       # out/intro.mp4
npm run render:spotlight   # out/feature-spotlight.mp4
npm run render -- Intro out/intro.mp4   # any composition, any output
npm run still -- Intro out/intro.png 30 # single frame at frame 30
npm run lint         # eslint + TypeScript
```

`npm run render` without arguments offers an interactive picker of
compositions.

## Compositions

| ID | Size | Length | Purpose |
| --- | --- | --- | --- |
| `Intro` | 1920×1080 | 6 s | Branded opener with logo mark and tagline |
| `FeatureSpotlight` | 1080×1920 | 5 s | Vertical social clip showing natural-language search |

## Layout

```
src/
  index.ts                 registers the Remotion root
  Root.tsx                 composition metadata and defaults (inline, Studio-editable)
  theme.ts                 shared colors and font stack
  Intro.tsx                landscape opener
  FeatureSpotlight.tsx     vertical feature clip
  components/
    Backdrop.tsx           gradient + grid background
    Mark.tsx               animated app mark
public/                    static assets, referenced with staticFile()
out/                       rendered output (git-ignored)
```

## Conventions

- Animate with `useCurrentFrame()` and `interpolate()`. CSS transitions,
  CSS animations and Tailwind animation classes do not render correctly.
- Use the `scale`, `translate` and `rotate` CSS shorthands instead of
  `transform` strings so values stay editable in Studio.
- Keep `useCurrentFrame()` in the smallest component that needs it.
- Convert seconds to frames with `fps` from `useVideoConfig()`.
- Keep composition props in the inline `defaultProps` object in `Root.tsx` so
  Studio can write edits back.
- Add packages with `npx remotion add <package>` so versions stay aligned.
- Put assets in `public/` and load them with `staticFile()`.

## Recording app footage

Put screen recordings in `public/`, then embed them with `<Video>` from
`@remotion/media` (install once with `npx remotion add @remotion/media`):

```tsx
<Video src={staticFile("library-browse.mp4")} />
```

Trim and offset with `trimBefore` / `trimAfter` in frames.
