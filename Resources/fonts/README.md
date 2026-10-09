# Fonts

The typefaces vestal draws with (`theme.typeface`, `theme.fonts`, the clock faces; `vestal docs styling`). All are licensed under the SIL Open Font License 1.1: each directory carries its `OFL.txt`, and the fonts are unmodified. Variable fonts where upstream ships them; IBM Plex Mono is one file per weight.

The apps register them with the platform's font system for their own process only (CoreText on macOS, fontconfig on Linux, `@font-face` in the web renderer); nothing is installed system-wide.

Source: the Google Fonts repository at commit `51303ca9e8ac9dcea7b12d307ba568fd0e6fcfca`, `https://raw.githubusercontent.com/google/fonts/51303ca9e8ac9dcea7b12d307ba568fd0e6fcfca/ofl/<upstream directory>/<file>`. File names have their axis tags (`[wght]`) replaced by `-Variable`. To update a family, download the new file from its upstream, replace it here, and update this table.

## Geist

- Directory: `geist/` (upstream `ofl/geist/`); project: https://github.com/vercel/geist-font
- Copyright: Vercel. License: SIL OFL 1.1 (`geist/OFL.txt`)
- Used by: typeface geist; sans

| File | Bytes | SHA-256 |
|---|---|---|
| `Geist-Variable.ttf` (upstream `Geist[wght].ttf`) | 169056 | `73894e0448cae90a92b6c2f8732b7bb9acb7b94c418bff559dad4a18e1de9659` |
| `OFL.txt` | 4387 | `1781d2806a07d91c4edf4740b88449fab7d0eadad53f7c351b94cd4d4eb8c00f` |

## Geist Mono

- Directory: `geist-mono/` (upstream `ofl/geistmono/`); project: https://github.com/vercel/geist-font
- Copyright: Vercel. License: SIL OFL 1.1 (`geist-mono/OFL.txt`)
- Used by: typeface geist (display, mono)

| File | Bytes | SHA-256 |
|---|---|---|
| `GeistMono-Variable.ttf` (upstream `GeistMono[wght].ttf`) | 171948 | `d00e590b8eb3a59acc329b2d044fd143ae935090b7da33199ebee27cc7de8196` |
| `OFL.txt` | 4387 | `1781d2806a07d91c4edf4740b88449fab7d0eadad53f7c351b94cd4d4eb8c00f` |

## Inter

- Directory: `inter/` (upstream `ofl/inter/`); project: https://github.com/rsms/inter
- Copyright: The Inter Project Authors. License: SIL OFL 1.1 (`inter/OFL.txt`)
- Used by: typeface inter (sans)

| File | Bytes | SHA-256 |
|---|---|---|
| `Inter-Variable.ttf` (upstream `Inter[opsz,wght].ttf`) | 876576 | `29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031` |
| `OFL.txt` | 4377 | `5b9321a4298cfeb6b34354164a1c3afc3db114569984c502b9b35d988fd58c57` |

## Inter Tight

- Directory: `inter-tight/` (upstream `ofl/intertight/`); project: https://github.com/rsms/inter-tight
- Copyright: The Inter Project Authors. License: SIL OFL 1.1 (`inter-tight/OFL.txt`)
- Used by: typeface inter (display); the thin clock face

| File | Bytes | SHA-256 |
|---|---|---|
| `InterTight-Variable.ttf` (upstream `InterTight[wght].ttf`) | 581588 | `b81b73dcb64df3c230cabade7df6c5773bf863233f24c9ee51087519f1f88b6f` |
| `OFL.txt` | 4383 | `50240ab035cf1b6b3307940235481d515c4b6de3ab1fa843dbe59e7892cb9d58` |

## JetBrains Mono

- Directory: `jetbrains-mono/` (upstream `ofl/jetbrainsmono/`); project: https://github.com/JetBrains/JetBrainsMono
- Copyright: JetBrains. License: SIL OFL 1.1 (`jetbrains-mono/OFL.txt`)
- Used by: typefaces inter and instrument (mono)

| File | Bytes | SHA-256 |
|---|---|---|
| `JetBrainsMono-Variable.ttf` (upstream `JetBrainsMono[wght].ttf`) | 187208 | `48715a42ec242c21e9f02692891e147d022299a52e48d5e413e1a942193ffeda` |
| `OFL.txt` | 4399 | `b2fe5e8987594e9ffd1d2ca52a2f5d73eb8335243893c5d6254b5ad69269591d` |

## IBM Plex Sans

- Directory: `ibm-plex-sans/` (upstream `ofl/ibmplexsans/`); project: https://github.com/IBM/plex
- Copyright: IBM Corp.. License: SIL OFL 1.1 (`ibm-plex-sans/OFL.txt`)
- Used by: typeface plex (display, sans)

| File | Bytes | SHA-256 |
|---|---|---|
| `IBMPlexSans-Variable.ttf` (upstream `IBMPlexSans[wdth,wght].ttf`) | 537244 | `3b031aa4216174205bd8471f88a49b91f093169e9e87bd5262242bc5967fe2e3` |
| `OFL.txt` | 4456 | `7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da` |

## IBM Plex Mono

- Directory: `ibm-plex-mono/` (upstream `ofl/ibmplexmono/`); project: https://github.com/IBM/plex
- Copyright: IBM Corp.. License: SIL OFL 1.1 (`ibm-plex-mono/OFL.txt`)
- Used by: typeface plex (mono)

| File | Bytes | SHA-256 |
|---|---|---|
| `IBMPlexMono-Thin.ttf` | 137900 | `c44c820c14b4f1b818344e5f5dc189cee98b1d5e56b4e80055496c228f3cc7ea` |
| `IBMPlexMono-ExtraLight.ttf` | 135980 | `826b765bd5173b97d521053330a66277edc224f8cc5f1e0035df1d995d5f003c` |
| `IBMPlexMono-Light.ttf` | 135216 | `780bcf65509d72a35ec114b57bcbe220dc6b77d8ea2e9b25e294be3c570c5025` |
| `IBMPlexMono-Regular.ttf` | 135580 | `6a3412f058c7d8dfd9170c41e85ade48e5156ecb89356110ca57a0a27734af46` |
| `IBMPlexMono-Medium.ttf` | 136704 | `a9b4c49bb299e05b5f6c481e7fb5e78943d2793249a0c8874ab574a2d1ea6755` |
| `IBMPlexMono-SemiBold.ttf` | 140216 | `d3c38e55c78f5b0f28009fddba4834ec503278936a5986032424c9bd2d23aa46` |
| `IBMPlexMono-Bold.ttf` | 137784 | `ac27abd6450a64dd94467580a02fe6235156d5b92f2926ebbc8e7489df64e0be` |
| `OFL.txt` | 4456 | `7e6b2818edbd8f6a01ae80641cc8f16a51080d08fb4e532be3a0b6f74adb07da` |

## Instrument Serif

- Directory: `instrument-serif/` (upstream `ofl/instrumentserif/`); project: https://github.com/Instrument/instrument-serif
- Copyright: Instrument. License: SIL OFL 1.1 (`instrument-serif/OFL.txt`)
- Used by: typeface instrument (display); the serif clock face

| File | Bytes | SHA-256 |
|---|---|---|
| `InstrumentSerif-Regular.ttf` | 70012 | `498efd461f6ddfcb7a111bf9a565709d2085d48201d501ead960d93e84ffbb88` |
| `OFL.txt` | 4405 | `129ed7618959716959f2941fdd5b49e0ad6e6c1d78726761786a00253d865521` |

## Instrument Sans

- Directory: `instrument-sans/` (upstream `ofl/instrumentsans/`); project: https://github.com/Instrument/instrument-sans
- Copyright: Instrument. License: SIL OFL 1.1 (`instrument-sans/OFL.txt`)
- Used by: typeface instrument (sans)

| File | Bytes | SHA-256 |
|---|---|---|
| `InstrumentSans-Variable.ttf` (upstream `InstrumentSans[wdth,wght].ttf`) | 194336 | `b24f1812584816958afcf22e22d08e44318c5e51651e25d2438efdde389b33b1` |
| `OFL.txt` | 4403 | `9e27a72ed30eb49a08678f6a5d6ed98ec7ba5368f541637ee0683ec9134ef966` |

## Fira Code

- Directory: `fira-code/` (upstream `ofl/firacode/`); project: https://github.com/tonsky/FiraCode
- Copyright: The Fira Code Project Authors. License: SIL OFL 1.1 (`fira-code/OFL.txt`)
- Used by: typeface fira (every role)

| File | Bytes | SHA-256 |
|---|---|---|
| `FiraCode-Variable.ttf` (upstream `FiraCode[wght].ttf`) | 260364 | `9335b082b3c7850d98a64b584f3417f65355f3471278bb5eeb8c6c0e8657aeeb` |
| `OFL.txt` | 4391 | `926041dac670e6922505e35ac1661a4e8d20f1ffeabbbcb5edb5544370702369` |

## Big Shoulders Display

- Directory: `big-shoulders-display/` (upstream `ofl/bigshouldersdisplay/`); project: https://github.com/xotypeco/big_shoulders
- Copyright: The Big Shoulders Project Authors. License: SIL OFL 1.1 (`big-shoulders-display/OFL.txt`)
- Used by: the condensed clock face

| File | Bytes | SHA-256 |
|---|---|---|
| `BigShouldersDisplay-Variable.ttf` (upstream `BigShouldersDisplay[wght].ttf`) | 219532 | `60e208dc276a1c35fc5b62e94f9fb959c40c11783a9eb7548175c14b1fbeb720` |
| `OFL.txt` | 4396 | `338f9c050f19daeda1d597243faf79f3a3d437c338af58cb7047617d0ce08771` |

## Space Grotesk

- Directory: `space-grotesk/` (upstream `ofl/spacegrotesk/`); project: https://github.com/floriankarsten/space-grotesk
- Copyright: Florian Karsten. License: SIL OFL 1.1 (`space-grotesk/OFL.txt`)
- Used by: the stacked clock face

| File | Bytes | SHA-256 |
|---|---|---|
| `SpaceGrotesk-Variable.ttf` (upstream `SpaceGrotesk[wght].ttf`) | 136676 | `acad6de1fc93436f5c0f1f4137751ef04f1aea3063e7036535970ffcfbd79f72` |
| `OFL.txt` | 4495 | `564ce565c371c5e5bbf286006565a7c9aa55a9f56e7ca58d56e05d649dd61a72` |

## Manrope

- Directory: `manrope/` (upstream `ofl/manrope/`); project: https://github.com/googlefonts/manrope
- Copyright: Mikhail Sharanda. License: SIL OFL 1.1 (`manrope/OFL.txt`)
- Used by: the breathe clock face

| File | Bytes | SHA-256 |
|---|---|---|
| `Manrope-Variable.ttf` (upstream `Manrope[wght].ttf`) | 164700 | `3ae11c49db0455a3cc33e37d380f20fdb8c7f8b41dc07625c177e3d87a9d6ae6` |
| `OFL.txt` | 4387 | `58172e0c0fac2cda8a37b348164bb55e44b0e69051e557e92b1d3f6910141f7b` |

## Nunito

- Directory: `nunito/` (upstream `ofl/nunito/`); project: https://github.com/googlefonts/nunito
- Copyright: Vernon Adams, Jacques Le Bailly. License: SIL OFL 1.1 (`nunito/OFL.txt`)
- Used by: the rounded clock face

| File | Bytes | SHA-256 |
|---|---|---|
| `Nunito-Variable.ttf` (upstream `Nunito[wght].ttf`) | 276932 | `bb55a5ca5c2042335b3991af27c4d0705d0ef41cac6164ac737fd8f2a1e85207` |
| `OFL.txt` | 4385 | `580df76c95a1ec5ab878ceb25bb3d85c6a076804e9c970c8c6972aea775fdf65` |

Total: 4867259 bytes of font files in 14 families.
