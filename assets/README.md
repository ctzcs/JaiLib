# Built-in assets

These are shipped resources, not disposable build outputs. New projects created
with `tools/new-game` receive their own copy of `fonts/` and `icons/`.

| Resource | Location | Use |
| --- | --- | --- |
| Noto Sans CJK SC subset | `fonts/NotoSansCJKsc-Regular-subset.otf` | ImGui font baking; 7,619 code points |
| Noto MSDF atlas | [fonts/msdf](fonts/msdf/README.md) | Game text and UI; 509 glyphs, including a limited Chinese character set |
| Game Icon Pack v1.4 atlas | [icons](icons/README.md) | 815 named icons in 12 categories, PNG + XML |
| Foster default Roboto atlas | `../foster/content/fonts/Compiled/` | Embedded default MSDF font and license |
| Foster desktop shaders | `../foster/content/shaders/` | Batcher, Textured, and MSDF sources and compiled backend variants |
| Foster Web shaders | `../foster/internal/web/shaders/` | GLSL sources adapted to JaiLib's Web backend |

The OTF, icon PNG/XML, and font license match olib's root assets byte for byte.
The Noto MSDF files were copied from olib's `tools/new-game/template/assets/fonts`;
they live here once so library users and generated projects share the same source.
Foster shader locations differ from olib's `foster/assets/shaders`: JaiLib uses
its own runtime-compatible copies, including local Web fixes.

Font licenses and source details are stored alongside the files. The icon pack's
license information is still incomplete; see its README for the existing provenance
record. No license is inferred from the repository's code license.
