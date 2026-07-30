# ai-cli-termux

Instalador y verificador unificado de CLIs de IA en **Termux** (Android aarch64),
sin proot, usando el overlay glibc del ecosistema Termux.

## Por qué existe

Las CLIs de IA modernas se distribuyen como binarios glibc compilados para Linux.
Termux usa bionic libc. En lugar de correr uno dentro de proot-distro (virtualización
completa) o mantener un repositorio separado por cada herramienta, este proyecto
provee un instalador genérico parametrizado por archivo de configuración.

Agregar una herramienta nueva = crear un archivo en `registry/`.

## Arquitectura

```
Termux (bionic libc)
  └─ glibc overlay ($PREFIX/glibc/lib/ld-linux-aarch64.so.1 + libs)
       └─ binario oficial Linux ARM64 (patchelf'd PT_INTERP + DT_RUNPATH)
```

`patchelf` reescribe los campos `PT_INTERP` y `DT_RUNPATH` del ELF para apuntar
al loader y las librerías del overlay glibc de Termux. No se modifica código ni
lógica del programa.

## Herramientas disponibles

| Herramienta | Repo / Fuente | Verificación |
|---|---|---|
| `opencode` | [anomalyco/opencode](https://github.com/anomalyco/opencode) | SHA256 + GitHub attestation |
| `agy` | [antigravity.google](https://antigravity.google) — Google Cloud Storage | SHA512 desde manifest JSON |

## Requisitos

- Android 10+ (aarch64)
- Termux desde F-Droid o GitHub (**NO** Google Play, está desactualizado)
- ~400 MB libres por herramienta

## Instalación

```bash
pkg install git -y
git clone https://github.com/TU_USUARIO/ai-cli-termux.git
cd ai-cli-termux
bash install.sh <herramienta>
```

### OpenCode

```bash
bash install.sh opencode           # última release registrada
bash install.sh opencode -v 1.18.9 # versión específica
bash install.sh opencode -r        # forzar reinstalación
bash install.sh opencode -u        # desinstalar
bash install.sh opencode --require-attestation  # exigir firma de GitHub
```

> El diseño es **fail-closed**: si la versión detectada no tiene hash en
> `sha256.txt`, el script aborta antes de descargar nada. Para instalar una
> versión nueva, agregá su hash al archivo (instrucciones en `sha256.txt`).

### Antigravity CLI (agy)

```bash
bash install.sh agy    # instala la última versión disponible en el manifest de Google
bash install.sh agy -r # forzar reinstalación
bash install.sh agy -u # desinstalar
```

> `agy` obtiene el checksum SHA512 directamente del manifest JSON de Google,
> no de `sha256.txt`. No hay GitHub attestation disponible para esta herramienta.

## Verificación

```bash
bash verify.sh opencode
bash verify.sh agy
```

Comprueba: manifest, binario (presencia, permisos, formato ELF64 aarch64),
interpreter y rpath patcheados, integridad del binario instalado, coherencia con
`sha256.txt`, estado de la attestation, wrapper (`LD_PRELOAD`/`LD_LIBRARY_PATH`),
loader glibc, `nsswitch.conf`, y ejecución real. Sale con código 1 si hay fallos.

## Uso post-instalación

```bash
opencode              # iniciar OpenCode en el directorio actual
agy                   # iniciar Antigravity CLI
```

## Agregar una herramienta nueva

1. Creá `registry/<nombre>.conf` basándote en los ejemplos existentes.
2. Si la herramienta usa GitHub Releases con SHA256, agregá los hashes a `sha256.txt`.
3. Si usa un manifest JSON remoto (como `agy`), configurá `RELEASE_SOURCE=manifest_json` y `MANIFEST_URL`.
4. Opcional: definí `pre_wrapper_hook()` o `post_install_hook()` en el `.conf` para
   pasos específicos de esa herramienta.

## Estructura del proyecto

```
ai-cli-termux/
├── install.sh          # instalador genérico
├── verify.sh           # verificador genérico
├── sha256.txt          # hashes de tarballs (fuente de verdad para GitHub Releases)
└── registry/
    ├── opencode.conf   # config de OpenCode
    └── agy.conf        # config de Antigravity CLI
```

## Seguridad

### Modelo de integridad en dos capas

`patchelf` modifica los bytes del binario, por lo que existen **tres hashes
distintos** para la misma versión: tarball, binario extraído, y binario post-patchelf.

| Artefacto | Hash | ¿Fuente? |
|---|---|---|
| Tarball del release | SHA256 / SHA512 | `sha256.txt` o manifest JSON remoto |
| Binario extraído | (intermedio) | registrado en `manifest.txt` |
| Binario post-patchelf | SHA256 / SHA512 | registrado en `manifest.txt` |

1. **En la instalación** (`install.sh`): se verifica el **tarball** contra el
   hash registrado (fail-closed) y, si está configurado, la release attestation
   firmada por GitHub.
2. **Después de instalar** (`verify.sh`): se verifica el **binario post-patchelf**
   contra el hash en `manifest.txt`, detectando modificaciones posteriores.

### Alcance de la protección

- El hash pineado protege contra corrupción en tránsito y reemplazo del asset.
  Es un modelo TOFU: la confianza inicial viene de quien registró el hash.
- La attestation de GitHub (`--require-attestation`, solo para OpenCode) provee
  verificación criptográfica (Sigstore/OIDC): prueba que el tarball salió de
  un workflow de GitHub Actions de `anomalyco/opencode`.
- Para `agy`, el hash SHA512 viene del manifest de Google (HTTPS + TLS mutual auth
  contra `*.run.app`). No hay attestation adicional.
- `manifest.txt` es un archivo **sin firmar** en el mismo directorio que el binario.
  Protege contra corrupción accidental y modificaciones oportunistas, pero no contra
  un atacante con permisos de escritura en ese path.

### Limitaciones conocidas en Termux

#### Shebangs rotos en procesos hijos

El wrapper hace `unset LD_PRELOAD` (necesario: `libtermux-exec.so` es bionic y
crashea procesos glibc). Eso desactiva el interceptor de `execve()` que reescribe
shebangs. Scripts con `#!/bin/bash` o `#!/usr/bin/env node` fallarán con `ENOENT`.

**Mitigación**: `termux-fix-shebang` sobre los scripts afectados. Las herramientas
ELF (`git`, `node`, `rg`) no se ven afectadas.

#### Colisión de LD_LIBRARY_PATH

El wrapper hace `unset LD_LIBRARY_PATH` para evitar que librerías bionic heredadas
provoquen segfault al enlazar con glibc.

#### DNS

glibc necesita `nsswitch.conf`. `install.sh` lo crea automáticamente si falta.
Si hay problemas de resolución, verificá que `$PREFIX/glibc/etc/nsswitch.conf` exista.

#### Fragilidad ante actualizaciones del stack glibc

Si Termux actualiza el overlay glibc (versión, rutas, estructura), el binario
patcheado puede dejar de encontrar el loader. `verify.sh` lo detecta en el check
de ejecución real. Solución: `bash install.sh <herramienta> -r`.

## Desinstalación

```bash
bash install.sh opencode -u
bash install.sh agy -u

# Manual:
rm -rf "$PREFIX/libexec/opencode" "$PREFIX/bin/opencode"
rm -rf "$PREFIX/libexec/agy"      "$PREFIX/bin/agy"
# Opcional:
pkg remove glibc-runner patchelf glibc-repo
```

## Referencias

- [OpenCode GitHub](https://github.com/anomalyco/opencode)
- [Antigravity CLI](https://antigravity.google/docs/cli/reference)
- [glibc-packages de Termux](https://github.com/termux/glibc-packages)
- [glibc-runner (grun)](https://github.com/termux-pacman/glibc-packages/wiki/About-glibc-runner-(grun))
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations)
- [gh release verify-asset](https://cli.github.com/manual/gh_release_verify-asset)
- [Termux-exec — reescritura de shebangs](https://wiki.termux.com/wiki/Termux-exec)
