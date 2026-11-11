# Third-party notices

## PaperWM.spoon

The Mission Control drag sequence in `Sources/PaperiPlatform/SpaceTransfer.swift` (used only by the `paperi mission-control-move` test aid) is adapted from
[`mission_control.lua`](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/mission_control.lua),
revision `f86f76bae635307d6cb12c8d66693acff57cf82a`.

MIT License

Copyright (c) 2022 Michael Mogenson

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## Design inspirations and implementation references

Paperi's scrolling layout and macOS workflow draw on
[PaperWM](https://github.com/paperwm/PaperWM) and
[PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon).
Palm webOS inspired the card-like motion, upward dismissal, and original Paperi
icon. [Sleipnir](https://www.fenrir-inc.com/jp/iphone/apps/sleipnir-mobile/help/iphone.html),
by Fenrir, inspired the directional gesture vocabulary.

[Hammerspoon](https://github.com/Hammerspoon/hammerspoon) and
[yabai](https://github.com/asmvik/yabai) were studied as implementation references
for macOS window management. The [reference audit](docs/REFERENCE-AUDIT.md)
records the source revisions and mechanisms consulted. These acknowledgments
are distinct from the adapted code and license notice above.

Paperi's branding and animated README illustrations are original artwork;
no Palm or Fenrir artwork or code is included. These names identify independent
projects and their contributions or influence, without implying affiliation.
