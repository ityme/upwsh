# Theme preview assets

Each PNG is one prompt from `gallery.html`, captured from the real renderer and bundled JSON. The file name is the theme. The picture itself has no theme title. Sample identity is `user@host`; branch `dev`, exit code `7`, and elapsed time `2345ms` are fixtures. JetBrainsMono NFM supplies Powerline glyphs. Dark prompts use `#1a1b26`; `pure-daylight.png` uses white. Both READMEs link these files by name.

Colorful images include the blank line from `AddNewline`. Pure images do not.

## Regenerate

From the repository root, with Python 3 and PowerShell 7:

```powershell
python tests/render_theme_gallery.py
```

Serve `docs/` over HTTP. Playwright blocks `file:`. Keep a session with `-s=themes`, open the page, then screenshot each visible prompt:

```text
playwright-cli -s=themes open http://127.0.0.1:8765/docs/assets/themes/gallery.html
playwright-cli -s=themes screenshot '#pure-classic-state-3' --filename docs/assets/themes/pure-classic.png
playwright-cli -s=themes screenshot '#colorful-blue-state-3' --filename docs/assets/themes/colorful-blue.png
playwright-cli -s=themes close
```

Repeat for `pure-glacier`, `pure-ember`, `pure-quiet`, `pure-daylight`, `colorful-green`, `colorful-macaron`, `colorful-morandi`, `colorful-cyberpunk`, `colorful-retro`, and `colorful-memphis`. State `3` is Git, exit 7, 2.345 seconds. Do not capture the article heading. Both READMEs link these files by name.

## Normalize

Raw captures are 902×66 for pure themes and 902×94 for colorful themes (the blank line from `AddNewline`). Normalize every PNG to a uniform 902×66 with the prompt content vertically centered, using the terminal background color (`#1a1b26`, or `white` for `pure-daylight`):

```sh
ffmpeg -i IN.png -vf "pad=iw:110:0:22:color=#1a1b26,crop=iw:66:0:22" -frames:v 1 OUT.png
```

The shipped files are already normalized; rerun this step after recapturing.
