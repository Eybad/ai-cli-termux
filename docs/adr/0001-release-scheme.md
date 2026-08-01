# Releases de distribución en un repo dedicado

Los binarios compilados en CI (patrón "build en CI", hoy solo codex) se publican como releases en un repo de distribución dedicado (`Eybad/ai-cli-termux-dist`), no en el repo del proyecto: la página de releases del proyecto queda solo con releases del proyecto (`v1.0.0+`) y el repo de dist escala a N tools compilados sin ruido. El instalador resuelve la última versión instalable filtrando releases por asset (`ARCHIVE_TEMPLATE` expandido) en vez de `releases/latest`, porque en el repo de dist conviven releases de varios tools y releases sin assets.

Se eligió mirror de versión upstream (`vX.Y.Z` = versión de openai/codex) sobre una serie propia (`v0.1.0`): `verify.sh` compara la versión ejecutada contra el manifest y el pinning de `sha256.txt` indexa por tag — el mirror hace ambos funcionar sin fricción.

Publish cross-repo: el workflow corre en el repo del proyecto y publica en el dist con un PAT fine-grained del usuario (secret `DIST_REPO_TOKEN`); el `GITHUB_TOKEN` del workflow no puede escribir en otro repo. La attestation SLSA la emite el repo del proyecto (donde corre el workflow), por eso `registry/codex.conf` define `ATTEST_REPO` apuntando al repo emisor.
