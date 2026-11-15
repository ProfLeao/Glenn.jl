# Cheat sheet

`cheat_sheet.pdf` is generated, not edited. The source is the documentation page
[`docs/src/cheat_sheet.md`](../src/cheat_sheet.md), which is also published on
the documentation site, so there is exactly one place to change.

Regenerate after editing the source:

```bash
pandoc docs/src/cheat_sheet.md \
  -o docs/cheat_sheet/cheat_sheet.pdf \
  --pdf-engine=xelatex \
  -V documentclass=extarticle \
  -V fontsize=8pt \
  -V geometry:"margin=1.2cm,a4paper" \
  -V colorlinks=true
```

Requirements: Pandoc and a LaTeX installation with the `extsizes` package
(`extarticle` gives the 8 pt body size; the standard `article` class only offers
10–12 pt and the result runs to four pages instead of two).

Keep the source in Latin-1-friendly characters. Subscript digits, arrows and
`≈` are not present in every LaTeX font and will silently disappear from the
PDF; the page therefore uses `CO2`, `->` and `~=` instead.
