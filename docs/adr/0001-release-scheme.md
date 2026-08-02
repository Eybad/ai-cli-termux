# Releases de distribución en un repo dedicado

Los binarios compilados en CI (patrón "build en CI", hoy solo codex) se publican como releases en un repo de distribución dedicado (`Eybad/ai-cli-termux-dist`), no en el repo del proyecto: la página de releases del proyecto queda solo con releases del proyecto (`v1.0.0+`) y el repo de dist escala a N tools compilados sin ruido. El instalador resuelve la última versión instalable filtrando releases por asset (`ARCHIVE_TEMPLATE` expandido) en vez de `releases/latest`, porque en el repo de dist conviven releases de varios tools y releases sin assets.

Se eligió mirror de versión upstream (`vX.Y.Z` = versión de openai/codex) sobre una serie propia (`v0.1.0`): `verify.sh` compara la versión ejecutada contra el manifest y el pinning de `sha256.txt` indexa por tag — el mirror hace ambos funcionar sin fricción.

Publish cross-repo: el workflow corre en el repo del proyecto y publica en el dist con un PAT fine-grained del usuario (secret `DIST_REPO_TOKEN`); el `GITHUB_TOKEN` del workflow no puede escribir en otro repo. La attestation SLSA la emite el repo del proyecto (donde corre el workflow), por eso `registry/codex.conf` define `ATTEST_REPO` apuntando al repo emisor.

## Patch series con semver build metadata (vX.Y.Z+androidN)

Si el build de Android necesita un parche sobre el código upstream (no es el binario oficial + patchelf: es código que se compila distinto), el tag de dist lleva **build metadata semver** (`vX.Y.Z+androidN`, `N` = `patch_rev`, default 1):

- **El parche se genera, no se versiona**: `scripts/gen-codex-lock-patch.py` reescribe el source upstream de forma determinista y fail-closed (inventario de call sites; cualquier desvío aborta el build). El workflow aplica el generador al checkout del source y compila; un binario sin parche nunca se publica.
- **Por qué no `vX.Y.Z+1` ni una serie propia (`v0.146.0.1`)**: el build metadata se ignora en la precedencia semver (no hay riesgo de "actualización" accidental hacia el release roto) y Cargo tolera `version = "0.146.0+android1"` (`CARGO_PKG_VERSION` lo reporta, `cargo update --workspace` resincroniza el lock). Una serie propia rompería el mirror de versión (verify.sh compara versión contra manifest).
- **El instalador lo soporta como caso general**: `install.sh` preserva `+build` en versión y tag (`parse_version_tag`; el tag se reconstruye desde la versión completa con `+build`, no desde el núcleo) y `check_current` compara el **tag del manifest** (identifica el release exacto: `v0.146.0` ≠ `v0.146.0+android1`, así `--update` migra del release roto al parcheado). `verify.sh` compara núcleos normalizados, así que el asset `amd64` oficial (reporta `0.146.0`) convive en el mismo tag.
- **Re-emitir una corrección**: `patch_rev=2` → `vX.Y.Z+android2` (el gate de idempotencia es por tag de dist, no por versión upstream). Si upstream arregla el problema en std, `android_patch=false` vuelve al tag estándar.
- **Fallback fail-closed**: si el parche no aplica (source upstream cambiado), el workflow aborta y la última versión buena sigue instalable.

Caso de uso actual: `File::{try_,}{lock,lock_shared}` devuelven `Unsupported` en Android desde Rust 1.89 (flock no se usa en esa plataforma; rust-lang/rust#148325) → codex TUI/exec fallan. El shim `file_lock_shim` usa `flock(2)` directo en android (EWOULDBLOCK → `std::fs::TryLockError::WouldBlock`) y delega en std fuera de android.

### Detalle: los call sites llevan prefijo `crate::`

El generador reemplaza cada call site por `crate::file_lock_shim::<method>(&<recv>)`. El prefijo `crate::` es **obligatorio** (validado en CI): desde la línea de Rust 1.96+ un path no calificado hacia un módulo del crate root ya no resuelve cuando se usa desde un submódulo anidado (E0433, ni siquiera con `pub mod`); el caso del build amd64 (sin parche) compila porque el source upstream no usa ese patrón, y los call sites del propio `lib.rs` (arg0, message-history) no fallaban porque resuelven desde la raíz. La corrección de `patch_rev=2` (v0.146.0+android2) fue exactamente esto: prefijar los 17 call sites (amend.rs, certs.rs, writer_lock.rs, etc.) con `crate::`.
