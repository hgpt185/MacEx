import {
  AbsoluteFill,
  Easing,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { Backdrop } from "./components/Backdrop";
import { colors, fontFamily } from "./theme";

type Props = {
  badge: string;
  title: string;
  query: string;
  caption: string;
};

const Badge: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        padding: "14px 30px",
        borderRadius: 999,
        border: `1px solid ${colors.surfaceBorder}`,
        backgroundColor: "rgba(255, 255, 255, 0.04)",
        color: colors.accent,
        fontFamily,
        fontSize: 26,
        fontWeight: 600,
        letterSpacing: "0.14em",
        textTransform: "uppercase",
        opacity: interpolate(frame, [0, 0.5 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(frame, [0, 0.7 * fps], ["0px -16px", "0px 0px"], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.bezier(0.16, 1, 0.3, 1),
        }),
      }}
    >
      {text}
    </div>
  );
};

const Title: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        fontFamily,
        fontSize: 86,
        fontWeight: 700,
        lineHeight: 1.05,
        textAlign: "center",
        whiteSpace: "pre-line",
        color: colors.foreground,
        opacity: interpolate(frame, [0.2 * fps, 0.9 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [0.2 * fps, 1 * fps],
          ["0px 28px", "0px 0px"],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          },
        ),
      }}
    >
      {text}
    </div>
  );
};

const SearchField: React.FC<{ query: string }> = ({ query }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const start = 0.8 * fps;
  const end = 2.1 * fps;
  const visible = Math.round(
    interpolate(frame, [start, end], [0, query.length], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    }),
  );

  return (
    <div
      style={{
        width: 860,
        boxSizing: "border-box",
        padding: "34px 40px",
        borderRadius: 26,
        border: `1px solid ${colors.surfaceBorder}`,
        backgroundColor: colors.surface,
        boxShadow: "0 30px 90px rgba(0, 0, 0, 0.45)",
        display: "flex",
        alignItems: "center",
        gap: 26,
        opacity: interpolate(frame, [0.6 * fps, 1.1 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        scale: interpolate(frame, [0.6 * fps, 1.4 * fps], [0.94, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.spring({ damping: 18 }),
          output: "perceptual-scale",
        }),
      }}
    >
      <div
        style={{
          width: 30,
          height: 30,
          borderRadius: 999,
          border: `3px solid ${colors.muted}`,
          position: "relative",
          flexShrink: 0,
        }}
      >
        <div
          style={{
            position: "absolute",
            width: 3,
            height: 12,
            borderRadius: 999,
            backgroundColor: colors.muted,
            bottom: -8,
            right: -4,
            rotate: "-45deg",
          }}
        />
      </div>
      <div
        style={{
          fontFamily,
          fontSize: 40,
          color: colors.foreground,
          whiteSpace: "nowrap",
          overflow: "hidden",
        }}
      >
        {query.slice(0, visible)}
        <span
          style={{
            display: "inline-block",
            width: 3,
            height: 42,
            marginLeft: 4,
            backgroundColor: colors.accent,
            verticalAlign: "middle",
            opacity:
              frame < start || frame > end + 1.5 * fps
                ? Math.floor(frame / 8) % 2 === 0
                  ? 1
                  : 0
                : 1,
          }}
        />
      </div>
    </div>
  );
};

const ResultRow: React.FC<{ from: number; label: string; detail: string }> = ({
  from,
  label,
  detail,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const delay = from * fps;

  return (
    <div
      style={{
        width: 860,
        boxSizing: "border-box",
        padding: "24px 30px",
        borderRadius: 20,
        border: `1px solid ${colors.surfaceBorder}`,
        backgroundColor: "rgba(255, 255, 255, 0.035)",
        display: "flex",
        alignItems: "center",
        gap: 24,
        opacity: interpolate(frame, [delay, delay + 0.5 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [delay, delay + 0.8 * fps],
          ["0px 26px", "0px 0px"],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          },
        ),
      }}
    >
      <div
        style={{
          width: 54,
          height: 54,
          borderRadius: 14,
          flexShrink: 0,
          background: `linear-gradient(135deg, ${colors.accent}, ${colors.accentWarm})`,
          opacity: 0.9,
        }}
      />
      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div
          style={{
            fontFamily,
            fontSize: 30,
            fontWeight: 600,
            color: colors.foreground,
          }}
        >
          {label}
        </div>
        <div style={{ fontFamily, fontSize: 24, color: colors.muted }}>
          {detail}
        </div>
      </div>
    </div>
  );
};

const Caption: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        position: "absolute",
        bottom: 120,
        width: 860,
        textAlign: "center",
        fontFamily,
        fontSize: 32,
        lineHeight: 1.4,
        color: colors.muted,
        opacity: interpolate(frame, [3.1 * fps, 3.9 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
      }}
    >
      {text}
    </div>
  );
};

export const FeatureSpotlight: React.FC<Props> = ({
  badge,
  title,
  query,
  caption,
}) => {
  return (
    <AbsoluteFill>
      <Backdrop />
      <AbsoluteFill
        style={{
          alignItems: "center",
          justifyContent: "center",
          flexDirection: "column",
          gap: 42,
          paddingTop: 40,
          paddingBottom: 240,
          boxSizing: "border-box",
        }}
      >
        <Badge text={badge} />
        <Title text={title} />
        <div style={{ height: 12 }} />
        <SearchField query={query} />
        <div style={{ height: 8 }} />
        <ResultRow from={2.3} label="Keynote-2026.mp4" detail="2.4 GB · Videos" />
        <ResultRow from={2.6} label="Launch-cut.mp4" detail="1.1 GB · Videos" />
        <ResultRow from={2.9} label="Screen Recording.mov" detail="840 MB · Videos" />
      </AbsoluteFill>
      <Caption text={caption} />
    </AbsoluteFill>
  );
};
