# Mousü website

Static HTML, CSS and JavaScript. No build step or runtime dependencies.

## Preview

From the repository root:

```sh
python3 website/check.py
python3 -m http.server 8080 --bind 127.0.0.1 --directory website
```

Open <http://127.0.0.1:8080>.

## Download and deployment

Both Download links in `index.html` point directly to the current beta DMG on
GitHub Releases and work without JavaScript. For each release, update both URLs
and the version/requirements together. Beta links use an explicit tag because
GitHub's latest-release shortcut excludes prereleases. Publish and verify the
release asset before deploying the website.

`check.py --output /tmp/mousu-site` validates and stages the public files into an
empty directory. It excludes authoring tools and documentation. GitHub Pages
publishing uses the manual **Publish Mousü website** workflow on `main`; Pages
must first be configured to use GitHub Actions. Commits do not deploy the site.

## Artwork

Keep original PNGs alongside their delivery images. Regenerate from the
repository root as needed:

```sh
python3 website/prepare-assets.py       # Pillow: responsive WebP images
python3 website/render-motion-icons.py # Icon Composer, Pillow, NumPy: icon layers
python3 website/render-camera-light.py # HDR camera texture; standard library only
```

The page follows system appearance and motion preferences. Generation 26 icons
are the fallback when the browser cannot identify macOS 27. The HDR camera texture
loads only on identified Macs with browser and HDR display support. Other devices
use the normal green dot.
