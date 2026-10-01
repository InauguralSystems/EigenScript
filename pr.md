Closes #1216

The acceptance demo is [`examples/tidepool_modern_gfx.eigs`](examples/tidepool_modern_gfx.eigs). It produces this linked Tidepool frame by loading a PNG with `gfx_image_load`, drawing its motes with `gfx_image_draw`, and compositing overlaps under `gfx_blend of "add"`:

![Tidepool frame using image and additive-blend builtins](docs/assets/tidepool-modern-gfx.png)
