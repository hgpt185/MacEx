import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { colors } from "../theme";

export const Backdrop: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill style={{ backgroundColor: colors.background }}>
      <AbsoluteFill
        style={{
          backgroundImage:
            "radial-gradient(circle at 18% 12%, rgba(91, 140, 255, 0.32), transparent 55%), radial-gradient(circle at 84% 82%, rgba(168, 85, 247, 0.26), transparent 52%)",
          opacity: interpolate(frame, [0, 40], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      />
      <AbsoluteFill
        style={{
          backgroundImage:
            "linear-gradient(rgba(255, 255, 255, 0.055) 1px, transparent 1px), linear-gradient(90deg, rgba(255, 255, 255, 0.055) 1px, transparent 1px)",
          backgroundSize: "80px 80px",
          maskImage:
            "radial-gradient(circle at 50% 50%, black 25%, transparent 72%)",
          WebkitMaskImage:
            "radial-gradient(circle at 50% 50%, black 25%, transparent 72%)",
          opacity: 0.55,
          translate: interpolate(frame, [0, 120], ["0px 48px", "0px 0px"], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      />
    </AbsoluteFill>
  );
};
