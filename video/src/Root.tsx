import { Composition, Folder } from "remotion";
import { FeatureSpotlight } from "./FeatureSpotlight";
import { Intro } from "./Intro";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Folder name="MacEx">
        <Composition
          id="Intro"
          component={Intro}
          durationInFrames={180}
          fps={30}
          width={1920}
          height={1080}
          defaultProps={{
            title: "MacEx",
            tagline: "Every file, in its place.",
            footer: "macex.app",
          }}
        />
        <Composition
          id="FeatureSpotlight"
          component={FeatureSpotlight}
          durationInFrames={150}
          fps={30}
          width={1080}
          height={1920}
          defaultProps={{
            badge: "Feature",
            title: "Search the way\nyou think.",
            query: "large videos in Downloads",
            caption:
              "Natural language turns into visible, editable filters — no query syntax required.",
          }}
        />
      </Folder>
    </>
  );
};
