# bachman-install

Installatiescript voor Bachman op een lege Mac. De broncode staat in een private repo; dit script installeert de Xcode Command Line Tools, Homebrew en `gh`, laat je in de browser inloggen bij GitHub, clonet de repo en gaat verder met het script uit de clone.

```
curl -fsSL https://raw.githubusercontent.com/ronaldjonkers/bachman-install/main/bootstrap.sh | bash
```

Eerst kijken wat er gebeurt, zonder iets te wijzigen:

```
curl -fsSL https://raw.githubusercontent.com/ronaldjonkers/bachman-install/main/bootstrap.sh | bash -s -- --dry-run
```

Dit bestand is een kopie van `scripts/bootstrap.sh` uit de Bachman-repo. Na de clone draait altijd de versie uit de repo zelf.
