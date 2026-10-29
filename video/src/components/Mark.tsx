import { Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { colors } from "../theme";

export const Mark: React.FC<{ size?: number }> = ({ size = 176 }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.28,
        background: `linear-gradient(135deg, ${colors.accent}, ${colors.accentWarm})`,
        boxShadow: "0 40px 120px rgba(91, 140, 255, 0.45)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        opacity: interpolate(frame, [0, 18], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
        }),
        scale: interpolate(frame, [0, 30], [0.55, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.spring({ damping: 14 }),
          output: "perceptual-scale",
        }),
        rotate: interpolate(frame, [0, 30], ["-8deg", "0deg"], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.bezier(0.16, 1, 0.3, 1),
        }),
        translate: interpolate(
          frame,
          [40, 40 + fps * 0.6],
          ["0px 0px", "0px -8px"],
          {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
            easing: Easing.bezier(0.4, 0, 0.2, 1),
          },
        ),
      }}
    >
      <div
        style={{
          width: size * 0.46,
          height: size * 0.58,
          borderRadius: size * 0.06,
          backgroundColor: "rgba(255, 255, 255, 0.95)",
          boxShadow: "0 10px 30px rgba(8, 9, 13, 0.25)",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          gap: size * 0.05,
          padding: size * 0.09,
          boxSizing: "border-box",
        }}
      >
        {[0, 1, 2].map((index) => (
          <div
            key={index}
            style={{
              height: size * 0.045,
              width: index === 2 ? "55%" : "100%",
              borderRadius: 999,
              backgroundColor: index === 0 ? colors.accent : "#C9CFE0",
            }}
          />
        ))}
      </div>
    </div>
  );
};
