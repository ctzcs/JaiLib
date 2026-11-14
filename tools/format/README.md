# Jai formatting

Use jacket 0.35.1's `jaifmt` with the repository's `jacket.toml`:

```powershell
python tools/format/main.py --write
python tools/format/main.py --check
```

The default is `--check`. Set `JAIFMT` to the formatter executable, put it on
`PATH`, or set `JAIC` to a compiler installed alongside it. The runner uses the
same local jacket installation fallback as `tools/check`.

All tracked and untracked `.jai` sources are included; Git-ignored build outputs
and scratch files are excluded. Formatting uses four spaces, a target width of
120 columns, and at most one blank line. Comments, string contents, and long
expressions can exceed the target width.
