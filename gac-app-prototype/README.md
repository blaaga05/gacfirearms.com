# GAC Visual Builder Prototype

Updated Gassett Arms Company website prototype using the new GAC logo and a visual configurator.

## What changed
- New GAC logo used in header and hero area.
- AR-15 and Glock 19 builders now render a live visual configuration.
- Accessory choices include visual thumbnail previews.
- Selected optics, stock, handguard, light, muzzle device, magazine, sights, and finish update the center preview.
- Saved builds keep their visual configuration.
- Product catalog now uses illustrated platform previews instead of text icons.

## Run locally
Open `index.html` in a browser, or run:

```bash
python3 -m http.server 8080
```

Then visit `http://localhost:8080`.

## Production asset note
The current configurator uses custom vector illustration layers so the interaction is functional without third-party product photography. Replace these illustrations with licensed transparent PNG/WebP product layers as photography is obtained. Keep each accessory image on the same canvas and alignment so the configurator can swap layers without shifting the firearm.
