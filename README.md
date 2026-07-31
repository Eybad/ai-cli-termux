# ai-cli-termux

Instalador y verificador unificado para ejecutar CLIs de Inteligencia Artificial en **Termux** (Android `aarch64` y Linux `x86_64`) **sin proot**, utilizando el overlay de librerías `glibc` del ecosistema Termux.

---

## Por qué existe este proyecto

Las herramientas CLI de IA modernas (como `opencode`, `kiro-cli` o `antigravity`) se distribuyen como binarios ELF compilados dinámicamente para entornos Linux estándar (`glibc`). Por su parte, Android utiliza Bionic libc.

En lugar de requerir distribuciones completas virtualizadas vía `proot-distro` (con consumo elevado de memoria y almacenamiento) o mantener instaladores aislados por cada CLI, **`ai-cli-termux`** proporciona un framework modular y extensible accionado por registros de configuración en `registry/`.

> [!TIP]
> **Agregar una herramienta nueva a `ai-cli-termux` solo requiere crear un archivo `.conf` en la carpeta `registry/`.**

---

## Arquitectura de ejecución nativa

```
Android OS / Kernel Linux (aarch64)
  |
  +- Termux Environment (Bionic libc)
       +- Overlay glibc ($PREFIX/glibc/lib/ld-linux-aarch64.so.1)
            |
            +- 1. patchelf (Reescritura de PT_INTERP y DT_RUNPATH)
            +- 2. pre_wrapper_hook (Hex-patching de kernel, shims de navegador/clipboard)
            +- 3. Executable Wrapper (Environment: SSL_CERT_FILE, GODEBUG, LD_LIBRARY_PATH)
            |
            +- Binario ejecutado nativamente en Android (Sin VM, sin proot, rendimiento 1:1)
```

---

## Herramientas soportadas

| Herramienta | Distribución | Verificación de Integridad | Mitigaciones Específicas |
|---|---|---|---|
| **`opencode`** | [GitHub Releases](https://github.com/anomalyco/opencode) | SHA256 digest del asset desde la GitHub API + GitHub Attestation (Sigstore) | Invocación directa vía loader glibc (`NEEDS_PATCHELF=false`) |
| **`agy`** *(Antigravity CLI)* | [Google Cloud Storage](https://antigravity.google) (Manifest JSON) | SHA512 dinámico desde el manifest remoto | Parche VA39 ARM64 + faccessat2 + shim libc.so + DNS cgo |
| **`kiro-cli`** *(Kiro CLI)* | [CDN de Amazon](https://prod.download.cli.kiro.dev) | SHA256 desde `manifest.json` oficial del CDN | Manifest del CDN; última versión automática |

---

## Requisitos del sistema

- **Dispositivo**: Android 10+ (`aarch64`) o Host Linux (`x86_64`).
- **Termux**: Instalado exclusivamente desde **F-Droid** o **GitHub Releases** (*NO usar la versión de Google Play Store, está obsoleta*).
- **Paquetes base en Termux**:
  ```bash
  pkg install git python ca-certificates -y
  ```
- **Almacenamiento libre**: ~400 MB por herramienta (kiro-cli: ~1 GB, el tarball pesa ~500 MB).

---

## Instalación y uso

### 1. Clonar el repositorio
```bash
pkg install git -y
git clone https://github.com/Eybad/ai-cli-termux.git
cd ai-cli-termux
```

> [!NOTE]
> **Última versión automática:** desde la versión actual del instalador, ninguna herramienta requiere tocar `sha256.txt` para el flujo default. La versión y el checksum se resuelven automáticamente (fail-closed) desde el digest de la GitHub API (`opencode`), el manifest de Google (`agy`) o el manifest del CDN (`kiro-cli`). `sha256.txt` queda como **capa opcional de pinning** para verificaciones independientes del vendor o instalaciones reproducibles.

### 2. Comandos de instalación (`install.sh`)

#### OpenCode
```bash
bash install.sh opencode                     # Instala la última versión (digest SHA256 de GitHub)
bash install.sh opencode -v 1.18.9           # Instala una versión específica
bash install.sh opencode -r                  # Reinstalación forzada (clean install)
bash install.sh opencode -u                  # Desinstalación completa
bash install.sh opencode --update            # Actualiza a la última versión si hay una anterior
bash install.sh opencode --require-attestation  # Exige verificación de firma GitHub Attestation
```

#### Antigravity CLI (`agy`)
```bash
bash install.sh agy    # Obtiene e instala el último release del manifest oficial de Google
bash install.sh agy -r # Reinstalación forzada y re-aplicación de parches
bash install.sh agy -u # Desinstalar
```

#### Kiro CLI (`kiro-cli`)
```bash
bash install.sh kiro-cli          # Instala la última versión (manifest.json del CDN, fail-closed)
bash install.sh kiro-cli --update # Actualiza a la última versión disponible
bash install.sh kiro-cli -r       # Reinstalación forzada
bash install.sh kiro-cli -u       # Desinstalar
```

### 3. Ejecutar las herramientas instaladas
```bash
opencode   # Ejecuta OpenCode en el directorio actual
agy        # Ejecuta Antigravity CLI
kiro-cli   # Ejecuta Kiro CLI
```

---

## Verificación y auditoría de integridad (`verify.sh`)

El proyecto incluye un motor de diagnóstico unificado para auditar cualquier herramienta:

```bash
bash verify.sh opencode
bash verify.sh agy
bash verify.sh kiro-cli
```

El script `verify.sh` realiza una auditoría completa en **10 pasos secuenciales**:
1. **Comprobación de manifiesto local**: Verifica la existencia de `manifest.txt` y sus campos.
2. **Binario presente y ejecutable**: Presencia, permisos y formato ELF64 `aarch64` / `x86_64`.
3. **Validación patchelf**: Verifica que `PT_INTERP` apunte al loader glibc y `DT_RUNPATH` contenga las librerías glibc.
4. **Integridad post-modificación**: Compara el SHA256/SHA512 del binario instalado contra el registrado.
5. **Consistencia de registro**: Valida el tarball instalado contra `sha256.txt` (solo `CHECKSUM_SOURCE=hashfile`). El source se lee del manifest (con fallback al `.conf`) para no depender de cambios posteriores en la configuración.
6. **Verificación Attestation**: Revisa el estado de la firma criptográfica registrada al instalar.
7. **Wrapper**: Presencia, ejecutabilidad y limpieza de `LD_PRELOAD`/`LD_LIBRARY_PATH`.
8. **Entorno de ejecución**: Valida `ld-linux-aarch64.so.1`, `nsswitch.conf` y el resolver DNS de glibc.
9. **Prueba de ejecución real**: Evalúa la invocación `--version` y la compara contra la versión del manifest.
10. **Resultado**: Resumen de fallos y advertencias; exit code 1 si hay fallos.

---

## Soluciones técnicas e incompatibilidades de Android

### 1. Parche de Kernel VA39 + Syscall `faccessat2` (Antigravity CLI)

Google distribuye binarios compilados para Linux servidor que asumen un espacio de memoria virtual de 48 bits (**VA48**) y utilizan la syscall moderna `faccessat2`. En Android:
- La mayoría de kernels ARM64 exponen únicamente 39 bits de dirección virtual (`CONFIG_ARM64_VA_BITS=39`), provocando un crash inmediato por memoria (`MmapAligned() failed`).
- La política `seccomp` del kernel de Android bloquea `faccessat2` (syscall 439), matando el proceso con `SIGSYS`.

> [!IMPORTANT]
> **Solución nativa sin `proot`:** `ai-cli-termux` integra un script auditable de hex-patching local (`registry/patch_va39.py`), ejecutado automáticamente por Python 3 durante el `pre_wrapper_hook`.
> - Reescribe instrucciones ARM64 (`ubfx`/`lsl` bit 42→35) para ajustar la asignación de tags de TCMalloc a 39 bits.
> - Parchea el límite superior de `MmapAligned` de `1<<48` a `1<<39`.
> - Reemplaza la syscall `faccessat2` (nr 439) por `faccessat` (nr 48), totalmente permitida por seccomp.
> - Todo el parche ocurre en memoria localmente, sin descargar binarios modificados de terceros.
>
> **Fail-closed del parche:** el script sale con código de error si los parches críticos (extracción de tag `ubfx` o la máscara random de mmap) no se encuentran. En ese caso el instalador conserva el binario sin parchear (puede funcionar en dispositivos VA48) y avisa con un error.

### 2. Resolución DNS y TLS en binarios Go

En sistemas Android sin `proot`, el archivo `/etc/resolv.conf` no existe en la raíz del sistema.
- **Resolver DNS**: Se configura `GODEBUG=netdns=cgo` en el wrapper para forzar a Go a usar la función `getaddrinfo` de glibc.
- **Configuración de servidores DNS**: El instalador consulta dinámicamente las propiedades de Android (`getprop net.dns1`/`net.dns2`) mediante `pre_wrapper_hook` para construir `$GLIBC_PREFIX/etc/resolv.conf`, respetando la red o VPN activa del usuario, con fallback a DNS públicos (`8.8.8.8`/`1.1.1.1`).
- **Certificados SSL/TLS**: Se exporta `SSL_CERT_FILE` apuntando al almacén de certificados CA de Termux (`$PREFIX/etc/tls/cert.pem`).

### 3. Shim para Linker Script `libc.so` en glibc Termux

En la distribución glibc de Termux, `/data/data/com.termux/files/usr/glibc/lib/libc.so` es un script ASCII del linker en lugar de un objeto compartido ELF. Cuando un binario intenta cargar dinámicamente `libc.so`, el loader glibc falla con `invalid ELF header`.
- **Solución**: El hook crea un directorio de shim `$LIBEXEC_DIR/glibc-shim` donde `libc.so` y `libc.so.6` apuntan mediante symlink al ELF real (`libc.so.6`), inyectándolo en el `LD_LIBRARY_PATH` del wrapper.

### 4. Intercepción de Navegador y Portapapeles (`xdg-open` / `xclip`)

`glibc-runner` contiene un comportamiento crítico: si un proceso invoca mediante `posix_spawn` un binario inexistente (como `xdg-open` o `xclip`), el proceso hijo crashea silenciosamente.
- **Solución**: Se instalan automáticamente wrappers ligeros en `$PREFIX/bin` para `xdg-open`, `sensible-browser`, `xclip`, etc., redirigiendo la apertura de URLs a `termux-open-url` y el portapapeles a `termux-clipboard-set`.

---

## Cómo agregar una nueva CLI (`registry/`)

Para dar soporte a un nuevo CLI en este instalador:

1. Crea el archivo `registry/<herramienta>.conf`.
2. Define las variables clave:
   ```bash
   APP_NAME="mi-cli"
   DISPLAY_NAME="Mi CLI de IA"
   REPO="usuario/repo"
   RELEASE_SOURCE="github"  # o "manifest_json", "url_template"
   CHECKSUM_ALGO="sha256"
   ELF_NAME="mi-cli"
   NEEDS_PATCHELF=true
   ```
3. Agrega los hashes de las versiones soportadas a `sha256.txt` (o usa el workflow de GitHub Actions `.github/workflows/update-hashes.yml`).
4. Si la CLI requiere ajustes de entorno o parches, implementa la función `pre_wrapper_hook()` o `post_install_hook()`.
5. Usar los registros existentes en `registry/` como ejemplos canónicos.

### RELEASE_SOURCE

| Tipo | Requiere | Checksum |
|---|---|---|
| `github` | `REPO`, `ARCHIVE_TEMPLATE` | `release_digest` (SHA256 del asset vía GitHub API) o `hashfile` |
| `manifest_json` | `MANIFEST_URL`, `MANIFEST_KEY_*` | `manifest` remoto (agy: Google; kiro-cli: CDN de Amazon) |
| `url_template` | `DOWNLOAD_URL_TEMPLATE` | `hashfile` (sin uso actual; disponible para CDNs sin manifest) |

### CHECKSUM_SOURCE

| Fuente | Descripción | Fail-closed |
|---|---|---|
| `release_digest` | SHA256 del asset publicado por GitHub (campo `digest` de la API) | Sí |
| `manifest` | SHA256/SHA512 del manifest JSON remoto del vendor | Sí |
| `hashfile` | Hash pineado en `sha256.txt` (pin independiente del vendor) | Sí |
| `--sha256 <hash>` | Pin explícito por línea de comandos (valida formato hex) | Sí |

Con `release_digest`, si existe una entrada en `sha256.txt` para el tag instalado, **el pin del repo gana** (verificación independiente del vendor sin llamada extra a la API).

### Arch mapping

Termux `uname -m` → internal `ARCH`:
- `aarch64` → `arm64`; `x86_64` → `amd64`

Si un tool usa nombres distintos (opencode usa `x64`, kiro usa `aarch64`), definir `ARCH_OVERRIDE_AARCH64` / `ARCH_OVERRIDE_X86_64` en el `.conf`.

### sha256.txt (pinning opcional)

```
tool/vX.Y.Z         hash   # lookup sin arch (por defecto arm64)
tool/vX.Y.Z:amd64   hash   # lookup con arch explícito
```

El lookup prueba `key:${ARCH}` primero, luego `key` solo. Convención de arquitectura: las entradas arm64 se registran **sin** sufijo; las amd64 con `:amd64`. El workflow `update-hashes.yml` sigue esta convención y limpia entradas previas con match exacto por campo (awk, sin regex).

El flujo default de instalación **no requiere** este archivo (los checksums se resuelven automáticamente). Su rol es opcional:
- **Pin independiente del vendor**: si una entrada existe para el tag instalado, `install.sh` la prefiere sobre el digest remoto.
- **Reproducibilidad**: `-v <version>` con entrada registrada instala exactamente ese tag verificado.
- **Herramientas con `CHECKSUM_SOURCE=hashfile`** (CDNs sin manifest) siguen dependiendo de él.

### Pipeline de instalación

1. Preflight — detecta Termux, arquitectura, dependencias
2. Resolve version — según `RELEASE_SOURCE` (latest vía API/manifest, o `-v`)
3. Resolve checksum — pin de `sha256.txt` (si existe), digest de la GitHub API o manifest remoto; validación de formato hex también para `--sha256`
4. Check current — salta si ya instalado (`--update` avisa si ya estás al día)
5. Install deps — `pkg install` glibc-runner, patchelf, etc.
6. Download → verify tarball — fail-closed si mismatch
7. Verify attestation — solo si configurado, requiere `gh`
8. Extract & install — busca el ELF por nombre + arquitectura
9. Patch — modifica el binario para que ejecute contra el runtime glibc de Termux
10. Wrapper — script en `$PREFIX/bin/$APP_NAME` que exporta `WRAPPER_ENV` y ejecuta el binario; valida presencia y permisos del binario (fail-fast)
11. Verify install → write manifest → hooks

### Manifest de integridad

`write_manifest()` registra: `version`, `tag`, `release_source`, `checksum_algo`, `checksum_source`, `tarball_checksum`, `binary_checksum_original`, `binary_checksum_patched`, `needs_patchelf`, `interpreter`, `rpath`, `attestation`, `installed_at`. `verify.sh` lee estos valores del manifest (no del `.conf`) para detectar manipulación o cambios de configuración posteriores.

---

## Estructura del repositorio

```
ai-cli-termux/
├── install.sh                  # Instalador unificado posix
├── AGENTS.md                   # Instrucciones para AI agents que trabajen en este repo
├── verify.sh                   # Suite de verificación de 10 pasos
├── sha256.txt                  # Registro oficial de checksums verificados
├── registry/
│   ├── opencode.conf           # Configuración de OpenCode CLI
│   ├── agy.conf                # Configuración de Antigravity CLI
│   ├── kiro-cli.conf           # Configuración de Kiro CLI (Amazon)
│   └── patch_va39.py           # Script de hex-patching ARM64 para VA39 y faccessat2
└── .github/workflows/
    └── update-hashes.yml       # Workflow CI/CD para verificar attestations y actualizar sha256.txt
```

---

## Modelo de seguridad e integridad

### Doble capa de hashes y diferencias de garantía
Debido a que `patchelf` y `patch_va39.py` modifican el binario durante la instalación, el sistema registra dos checksums:
1. **Hash de distribución (Tarball)**: Verificado al descargar (Modelo *Fail-Closed*).
   - **Verificación contra Hash Independiente (`opencode` con pin)**: el hash esperado está pineado en `sha256.txt` dentro del repositorio local. Protege contra assets o CDNs de descarga comprometidos en GitHub. Además soporta verificación opcional con GitHub Attestations (Sigstore/OIDC).
   - **Verificación Autorreferencial (`opencode` por defecto, `agy`, `kiro-cli`)**: el SHA256/SHA512 se extrae dinámicamente del digest de la GitHub API o del manifest JSON del vendor (Google / Amazon). Protege contra corrupción en tránsito y errores de descarga, pero confía implícitamente en el endpoint de origen del vendor.
   - **Verificación con hash fijo (`kiro-cli` con pin)**: similar a `opencode`, el hash SHA256 está pineado en `sha256.txt` si se desea verificación independiente del CDN.
2. **Hash local post-instalación (Binario en ejecución)**: Calculado inmediatamente después de aplicar los parches y guardado en `manifest.txt`. `verify.sh` utiliza este hash para asegurar que el binario instalado localmente no haya sido adulterado a posteriori.

### Fail-closed en todos los caminos
- Sin hash verificado → no se instala (incluye `--sha256`: se valida formato hex antes de usar).
- Los parches críticos de `patch_va39.py` son obligatorios: si no se aplican, el binario parcheado no se usa.
- El wrapper falla rápido si el binario no existe o no es ejecutable.

---

## Licencia

Este proyecto está distribuido bajo la licencia [MIT](LICENSE).
