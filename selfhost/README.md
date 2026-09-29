# Self-hosted build: Xavier's Front

The image `k8s/` deploys is built without any of OpenFront Inc.'s proprietary
assets, and under its own name. Both are license requirements, not preferences:

- `LICENSING.md` says the `proprietary/` assets are "NOT licensed for use,
  modification, or redistribution" outside the official OpenFront.io service.
- `LICENSE`, "ADDITIONAL TERMS": a modified version "must not use 'OpenFront'
  as their primary title or imply official endorsement", and must keep the
  notice "© OpenFront and Contributors" visible.

## How

`apply.sh` runs on the image workflow's fresh checkout, right before
`docker build`. It:

1. **Swaps `proprietary/` for `selfhost/proprietary/`.** It first checks that
   every upstream file has a replacement at the same path, and fails otherwise.
   A proprietary asset added upstream therefore stops the build instead of
   shipping in the image.
2. **Renames the game** to "Xavier's Front": the `<title>` and `og:title` in
   `index.html`, `main.title` in every `resources/lang/*.json`, the installed-app
   name in `resources/manifest.json`, and the logo images' alt text.
3. **Removes the Steam promotions**, which sell OpenFront's Steam release: the
   store widget (home page on phones, end-of-game window), the footer's "Buy on
   Steam" button, the popup offering to open lobby links in the Steam app, and
   the setting that goes with it. The widget and button get the same treatment
   they already have inside the Steam app, and the end-of-game window shows one
   of its other promos instead.

Upstream's `proprietary/` stays untouched in git, so merging upstream never
conflicts on these files, and `npm run dev` still shows upstream's assets. The
swap only ever happens in a build.

Left as they are:

- **"© OpenFront™ and Contributors"**, in the footer and on the loading screen.
  The license requires it.
- **Strings naming OpenFront's website, servers and accounts**, such as "Manage
  your billing on the OpenFront website". They describe OpenFront's services,
  which is what they are; they are not the game's title.
- **Steam sign-in and account linking.** They go through OpenFront's API, which
  a standalone deployment cannot reach, and promote nothing.

## What replaces what

| Upstream file                                   | Replacement                                                    |
| ----------------------------------------------- | -------------------------------------------------------------- |
| `images/OpenFrontLogo.svg`, `OpenFrontLogo.png` | Pixel wordmark "XAVIER'S / FRONT", same 1364:259 slot          |
| `images/OpenFrontLogoDark.svg`                  | The same wordmark in light grey                                |
| `images/OpenFront.png`, `.webp`                 | The wordmark at 1310x298                                       |
| `images/OF.png`, `.webp`                        | "XF" monogram, the mobile background watermark                 |
| `images/Favicon.svg`                            | "XF" on the same 11x11 pixel grid                              |
| `fonts/OpenFront.ttf`                           | Press Start 2P (SIL Open Font License), for the version label  |
| `sounds/effects/game-start-alert.mp3`           | The repository's own `resources/sounds/effects/game-start.mp3` |
| `sounds/music/menu-theme.mp3`, `gameplay.mp3`   | Five seconds of silence each                                   |

Licenses for each are in `proprietary/LICENSE`. The artwork is original to this
fork and CC BY-SA 4.0, like the repository's other assets.

## Changing them

The images and the silent tracks are generated; the outputs are committed:

```sh
python3 selfhost/make-assets.py # needs rsvg-convert and cwebp (brew install librsvg webp)
```

To rename the game, change `NAME` in `apply.sh` and `WORDMARK` and `MONOGRAM`
in `make-assets.py`, then regenerate.

When upstream adds a file to `proprietary/`, the image build fails and names it.
Add a replacement at the same path under `selfhost/proprietary/`, with its
license in `selfhost/proprietary/LICENSE`.

## Building by hand

`apply.sh` rewrites the working tree, so run it in a throwaway worktree:

```sh
git worktree add ../xf-build HEAD
cd ../xf-build
selfhost/apply.sh
docker buildx build --platform linux/amd64 \
  --build-arg GIT_COMMIT="$(git rev-parse HEAD)" \
  -t xavierclavel/openfront:latest --push .
cd - && git worktree remove --force ../xf-build
```

## Not covered

- **The footer's GitHub link points to upstream.** AGPL §13 asks a modified
  version served over a network to offer users its own source, which is this
  fork.
