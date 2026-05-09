# SLAXML

Pure-Lua streaming and DOM XML parser, vendored from
[Phrogz/SLAXML](https://github.com/Phrogz/SLAXML).

| | |
|---|---|
| Version | v0.8 |
| License | MIT (see `LICENSE`) |
| Upstream | https://github.com/Phrogz/SLAXML |
| Last upstream activity | 2018 (still the canonical pure-Lua XML parser - feature-complete; XML grammar does not change) |
| v0.7 → v0.8 changes (only streaming parser, the file we bundle) | text callback signature extended to `text(text, cdata)`; bugfixes for comments / PIs after the root element and whitespace preservation. The DOM-builder breaking change (`doc.root` removed when `simple=true`) lives in `slaxdom.lua` upstream and is not bundled here. |

Bundled in the hub install tree at `lib/slaxml/slaxml.lua` so plugins
can `require "slaxml"` without operator-side install steps. The
`luadch-ng/scripts` plugin
[`ptx_RSSFeedWatch`](https://github.com/luadch-ng/scripts) uses this
to parse RSS / Atom feeds; future XML-needing plugins benefit from
the same bundle.

## Local upgrade procedure

If a future SLAXML release does land:

```sh
curl -L -o slaxml/slaxml.lua \
    https://raw.githubusercontent.com/Phrogz/SLAXML/master/slaxml.lua
# update the version line in this README + the inline header in slaxml.lua
```

That's it - no Makefile, no build step. The CMake `install(FILES ...)`
rule in the top-level `CMakeLists.txt` ships it as-is.
