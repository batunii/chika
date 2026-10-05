# Chika website

The GitHub Pages site lives in `docs/`. It uses the Chika mark, bundled Archivo and Anton fonts, and original comic artwork. The artwork illustrates a fictional story; it is not a capture of the app interface.

## The opening journey

The opening is a live browser scene. Eight distinct comic pages sit at different positions and depths in 3D space. Scrolling advances the camera through the rooftop, envelope, station, map, city window, bridge, greenhouse, and final meeting. Nearby pages pass the viewer while later pages come into view. Mouse movement adds a small look shift on desktop. The progress rail and four text chapters follow the same journey.

The camera uses CSS perspective and transforms driven by `docs/site.js`. It loads two optimized WebP artwork atlases (about 1.2 MB combined) after the opening enters view. It does not seek or play a video. If artwork decoding or 3D support fails, the poster remains visible. Reduced-motion visitors get the poster and can continue to the static sections.

Headlines reveal line by line, chapter labels and supporting copy follow in sequence, and links use matching directional arrows. These text transitions stop under reduced motion.

## Preview

```sh
python3 scripts/serve_site.py
```

Open `http://127.0.0.1:8766/`. GitHub Pages can later serve the default branch's `/docs` folder. The site uses relative asset paths so it also works under a repository path such as `/chika/`. Publishing is a separate repository setting and is not enabled by this work.

## Artwork

The source 2×2 PNG atlases are in `scripts/film-art/`; the optimized site copies are `docs/media/story-atlas-a.webp` and `docs/media/story-atlas-b.webp`. Each quadrant is a different story scene. The supporting `docs/media/courier-art.webp` illustration was generated as original comic artwork without text, logos, established characters, or UI. The site does not reuse the README's third-party comic screenshots as marketing artwork.
