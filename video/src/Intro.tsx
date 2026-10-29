import {
  AbsoluteFill,
  Easing,
  interpolate,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { Backdrop } from "./components/Backdrop";
import { Mark } from "./components/Mark";
import { colors, fontFamily } from "./theme";

type Props = {
  title: string;
  tagline: string;
  footer: string;
};

const Title: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        fontFamily,
        fontSize: 148,
        fontWeight: 700,
        color: colors.foreground,
        letterSpacing: interpolate(
          frame,
          [0.6 * fps, 1.7 * fps],
          ["0.34em", "0.01em"],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          },
        ),
        textIndent: "0.01em",
        opacity: interpolate(frame, [0.6 * fps, 1.2 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [0.6 * fps, 1.5 * fps],
          ["0px 32px", "0px 0px"],
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

const Tagline: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        fontFamily,
        fontSize: 38,
        fontWeight: 400,
        color: colors.muted,
        letterSpacing: "0.02em",
        opacity: interpolate(frame, [1.1 * fps, 1.8 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        translate: interpolate(
          frame,
          [1.1 * fps, 2 * fps],
          ["0px 18px", "0px 0px"],
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

const AccentLine: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        height: 5,
        borderRadius: 999,
        background: `linear-gradient(90deg, ${colors.accent}, ${colors.accentWarm})`,
        width: interpolate(frame, [1.6 * fps, 2.6 * fps], [0, 260], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.bezier(0.16, 1, 0.3, 1),
        }),
        opacity: interpolate(frame, [1.6 * fps, 2.1 * fps], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
      }}
    />
  );
};

const Footer: React.FC<{ text: string }> = ({ text }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        position: "absolute",
        bottom: 72,
        width: "100%",
        textAlign: "center",
        fontFamily,
        fontSize: 26,
        letterSpacing: "0.18em",
        textTransform: "uppercase",
        color: colors.muted,
        opacity: interpolate(frame, [2.4 * fps, 3.2 * fps], [0, 0.7], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
      }}
    >
      {text}
    </div>
  );
};

export const Intro: React.FC<Props> = ({ title, tagline, footer }) => {
  return (
    <AbsoluteFill>
      <Backdrop />
      <AbsoluteFill
        style={{
          alignItems: "center",
          justifyContent: "center",
          flexDirection: "column",
          gap: 44,
        }}
      >
        <Mark />
        <Title text={title} />
        <Tagline text={tagline} />
        <AccentLine />
      </AbsoluteFill>
      <Footer text={footer} />
    </AbsoluteFill>
  );
};
