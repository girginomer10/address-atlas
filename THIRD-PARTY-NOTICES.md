# Third-party notices

## Bundled fonts

The native Mac and iOS apps bundle these fonts. All are licensed under the
SIL Open Font License, Version 1.1. Each family's licence text, with its
copyright line, is shipped next to the font files in
`native/AddressAtlasMac/Sources/AddressAtlasMac/Fonts/<Family>/OFL.txt` and is
copied into the app bundles.

The files come from the `ofl/` directory of the Google Fonts repository
(`google/fonts`) and are used unmodified. Variable fonts are bundled where the
upstream project ships one.

| Family | Copyright | Upstream |
| --- | --- | --- |
| Plus Jakarta Sans | 2020 The Plus Jakarta Sans Project Authors | https://github.com/tokotype/PlusJakartaSans |
| Bricolage Grotesque | 2022 The Bricolage Grotesque Project Authors | https://github.com/ateliertriay/bricolage |
| Space Grotesk | 2020 The Space Grotesk Project Authors | https://github.com/floriankarsten/space-grotesk |
| Space Mono | 2016 The Space Mono Project Authors | https://github.com/googlefonts/spacemono |
| Geist | 2024 The Geist Project Authors | https://github.com/vercel/geist-font |
| Geist Mono | 2024 The Geist Project Authors | https://github.com/vercel/geist-font |
| Pixelify Sans | 2021 The Pixelify Sans Project Authors | https://github.com/eifetx/Pixelify-Sans |
| Silkscreen | 2001 The Silkscreen Project Authors | https://github.com/googlefonts/silkscreen |
| VT323 | 2011 The VT323 Project Authors | https://github.com/phoikoi/VT323 |

The fonts are only embedded in the apps. They are not loaded from the network,
so they add no entry to the privacy manifest.
