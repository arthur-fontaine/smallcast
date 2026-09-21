# Third-party notices

Smallcast is licensed under the GNU Affero General Public License v3 — see [LICENSE](LICENSE). It
also redistributes the third-party material recorded below, under the terms stated for each.

## Brand marks — `Smallcast/Assets.xcassets/AIBrand*.imageset`

Thirteen monochrome template SVGs, ~300 B–2 KB each, drawn beside a model's name in the model
picker and the chat header so a route is recognisable at a glance.

Every mark is the trademark of the company it identifies. Smallcast uses them only to name that
company's own models inside its own UI. No affiliation, sponsorship or endorsement is implied, and
none of these companies has reviewed or approved Smallcast.

### Simple Icons — twelve marks

`claude`, `deepseek`, `googlegemini`, `kimi`, `meta`, `minimax`, `mistralai`, `openai`,
`openrouter`, `perplexity`, `qwen` and `x`, from <https://github.com/simple-icons/simple-icons>.

The Simple Icons **project** is released under CC0 1.0 Universal. Its own disclaimer is explicit
that this does not extend to every mark the project carries: the icons depict third-party brands
whose trademarks stay with their owners, and the absence of licence data for a given icon does not
imply the icon is unlicensed. Anyone redistributing Smallcast, or reusing these files from it,
should read the disclaimer and satisfy themselves about the brands involved:
<https://github.com/simple-icons/simple-icons/blob/develop/DISCLAIMER.md>.

### Lobe Icons — one mark

`zai`, from <https://github.com/lobehub/lobe-icons>, which is MIT licensed. Its licence requires
this notice to travel with the work:

```
MIT License

Copyright (c) 2023 LobeHub

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
```

## Emo — `Smallcast/Features/Emoji/Model/EmoTokenizer.swift` and the downloaded model

Emoji suggestions use **Emo**, an on-device emoji classifier by Desert Ant Labs B.V.
(<https://desertant.com>, <https://huggingface.co/desert-ant-labs/emo>). Nothing of it ships in the
repository or the binary: when the feature is switched on, Smallcast downloads the Core ML export,
its tokenizer and its label sidecar at revision `v0.7.0` and verifies each against a recorded SHA-256.

`EmoTokenizer.swift` is a port of `Sources/Emo/Tokenizer.swift` from
<https://github.com/Desert-Ant-Labs/desert-ant-core> (v3.2.0), rewritten to compile with no
dependency on that package. It and the model are licensed under the **Desert Ant Labs Source-Available
License 1.0** (<https://license.desertant.com/1.0>, SPDX `LicenseRef-DAL-Source-Available-1.0`), not
under Smallcast's AGPL: free below 100,000 monthly active devices per platform, no use of the model or
its outputs to train a competing model, and attribution where users can find it — the Emoji pane's
footer carries "Powered by Emo from Desert Ant Labs". Anyone redistributing Smallcast should read that
licence, in particular its clause on distributing the SDKs themselves.
