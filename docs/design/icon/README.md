# App icon

`piopio-icon-light-original.png` and `piopio-icon-dark-original.png` are the icon as designed (1024 px, rounded square).

macOS 26+ applies its own icon shape, so the app ships full-bleed square artwork made from them with
`scripts/icon-fullbleed.py`, in the Icon Composer document `apps/mac/App/Piopio/AppIcon.icon`:
two groups, the light one hidden in dark appearance and the dark one hidden in light appearance.
Open it in Icon Composer (Xcode › Open Developer Tool) to adjust layers, glass or the tinted look.
