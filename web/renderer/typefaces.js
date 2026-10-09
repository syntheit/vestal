// The font files in Resources/fonts, as @font-face rules: [family, file, weight range].
// Variable fonts cover their whole range in one file; IBM Plex Mono ships one
// file per weight. Keep in step with Resources/fonts/README.md (a test checks the files).

export const FONT_FILES = [
  ["Geist", "geist/Geist-Variable.ttf", "100 900"],
  ["Geist Mono", "geist-mono/GeistMono-Variable.ttf", "100 900"],
  ["Inter", "inter/Inter-Variable.ttf", "100 900"],
  ["Inter Tight", "inter-tight/InterTight-Variable.ttf", "100 900"],
  ["JetBrains Mono", "jetbrains-mono/JetBrainsMono-Variable.ttf", "100 800"],
  ["IBM Plex Sans", "ibm-plex-sans/IBMPlexSans-Variable.ttf", "100 700"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-Thin.ttf", "100"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-ExtraLight.ttf", "200"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-Light.ttf", "300"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-Regular.ttf", "400"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-Medium.ttf", "500"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-SemiBold.ttf", "600"],
  ["IBM Plex Mono", "ibm-plex-mono/IBMPlexMono-Bold.ttf", "700"],
  ["Instrument Serif", "instrument-serif/InstrumentSerif-Regular.ttf", "400"],
  ["Instrument Sans", "instrument-sans/InstrumentSans-Variable.ttf", "400 700"],
  ["Fira Code", "fira-code/FiraCode-Variable.ttf", "300 700"],
  ["Big Shoulders Display", "big-shoulders-display/BigShouldersDisplay-Variable.ttf", "100 900"],
  ["Space Grotesk", "space-grotesk/SpaceGrotesk-Variable.ttf", "300 700"],
  ["Manrope", "manrope/Manrope-Variable.ttf", "200 800"],
  ["Nunito", "nunito/Nunito-Variable.ttf", "200 1000"],
];

/** The @font-face rules for the bundled families, loading from `base` (a URL with a trailing slash). */
export function fontFaceCSS(base) {
  return FONT_FILES.map(([family, file, weight]) =>
    `@font-face{font-family:"${family}";src:url("${base}${file}") format("truetype");font-weight:${weight};font-display:swap}`).join("\n");
}
