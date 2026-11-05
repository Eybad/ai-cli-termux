# Codex: caché de instrucciones en Android aarch64

El archivo generado `bionic_compat.c` deja `__clear_cache` sin definir. El
workflow extrae `clear_cache.c.o` de compiler-rt, incluido en el NDK cuyo
checksum ya verifica, y lo incorpora a `libbionic_compat.a`. Así la referencia
de V8 se resuelve con la implementación independiente del NDK. No se descarga
otra implementación ni se agrega una dependencia. La sincronización sigue activa.

La inclusión es explícita porque Rust enlaza con `-nodefaultlibs`: no alcanza
con confiar en las bibliotecas que Clang agrega por defecto. La ruta del
archivo estático incluye su digest SHA-256 y se usa en los RUSTFLAGS. Un
cambio en el shim o el objeto de caché cambia esos flags e invalida los
artefactos de Cargo restaurados del caché, forzando su reconstrucción.

El wrapper anterior invocaba `__builtin___clear_cache` y definía el símbolo
`__clear_cache` como alias del propio wrapper. En aarch64 el builtin genera una
llamada a ese símbolo, provocando recursión hasta SIGSEGV. Una regex como
`/a|b/` o `/[ab]/` alcanza esa ruta al generar código nativo en V8.

Referencias primarias:

- [Runtime de Clang y enlace de compiler-rt](https://clang.llvm.org/docs/Toolchain.html#compiler-runtime).
- [Implementación de `__clear_cache` en LLVM 17](https://github.com/llvm/llvm-project/blob/llvmorg-17.0.2/compiler-rt/lib/builtins/clear_cache.c).

## Gates del build

El job Android compila `scripts/codex-clear-cache-probe.c` con el mismo archivo
`libbionic_compat.a` y linker NDK del build. El probe genera y reemplaza código
AArch64 128 veces, sincroniza la caché y comprueba el valor ejecutado. Alterna
páginas RW y RX; no requiere páginas RWX.

En Ubuntu se compila e inspecciona el probe; no se ejecuta como si fuera un
binario Linux. `scripts/check-codex-clear-cache.py` inspecciona el objeto de
compiler-rt extraído, el probe y el host Android enlazado antes de empaquetarlo.
Rechaza definiciones de
`__clear_cache` en el shim, el alias antiguo, símbolos sin resolver, llamadas
desde la implementación de caché y ausencia de las instrucciones esperadas de
compiler-rt para AArch64 (`mrs ctr_el0`, `dc cvau`, `ic ivau`, `dsb ish`, `isb`).
Un cambio legítimo en compiler-rt puede requerir revisar este gate; el build
falla hasta que se revise. Estos controles estáticos no demuestran por sí solos
que el host Android ejecute correctamente las regex.

El job amd64 ejecuta `scripts/smoke-codex-code-mode.py` contra el host musl
verificado. El cliente abre sesiones sintéticas sin herramientas habilitadas,
ejecuta ambas regex por separado y exige resultado final `true`, sin error y
salida del proceso con 0. `execution/started` solo no cuenta como éxito.
La lectura y el cierre tienen un plazo limitado. Los tests sintéticos del
cliente corren en CI con `python3 scripts/test-codex-code-mode-smoke.py`.

## Verificación nativa pendiente de cada build Android

Con el probe y el host corregido disponibles en Termux, ejecutá:

```sh
./codex-clear-cache-probe
python3 scripts/smoke-codex-code-mode.py ./stage/codex-code-mode-host
```

El host debe tener sus bibliotecas compañeras junto al ejecutable y el RUNPATH
configurado por el workflow. Usá el bundle corregido en un directorio temporal;
no hace falta instalarlo ni reemplazar la instalación actual para probarlo.
El probe debe ser el enlazado con el shim del mismo build.

Un smoke amd64 aprobado no valida la ejecución Android. La prueba local del
probe con Clang de Termux tampoco sustituye la compilación con el NDK pineado
ni la ejecución del host Android completo. Registrar esas evidencias por
separado. Publicación e instalación siguen requiriendo autorización; una
re-emisión conserva checksums, attestation y una nueva revisión `+androidN`.

## Build de validación en GitHub Actions

El dispatch manual usa `publish=false` por defecto: compila ambas arquitecturas
sin publicar una release. El cron conserva la publicación automática anterior.
Para reconstruir una versión ya distribuida, elegí una nueva revisión
`patch_rev`; el gate de idempotencia sigue evitando sobrescribir releases.

El run entrega `codex-arm64`, `codex-amd64` y `validation-arm64`. Este último
contiene el probe del mismo build para su ejecución nativa en Termux. No forma
parte de los assets de distribución. La instalación existente no es necesaria
para probar los ejecutables extraídos del artifact.

## Evidencia del build 0.166.0+android2

Fecha: 2026-11-05.

- Run: [41960828923](https://github.com/Eybad/ai-cli-termux/actions/runs/41960828923),
  intento 1, concluido con éxito.
- Commit del workflow: `94953d56872b6bc6b2126839b56a841a63a2d4b9`.
- Source upstream pineado: `6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`.
- NDK r26d: checksum verificado por el workflow. Pasaron la inspección del
  objeto de compiler-rt, la del probe y la del host Android enlazado.
- El job amd64 completó ambas regex con resultado `true` y salida 0.
- `publish=false`: el job de release quedó omitido.

SHA256 de los ZIP informados por la API de Actions:

| Artifact | SHA256 |
|---|---|
| `codex-arm64` | `109fccfe50ee7df01b1e397d4270395f0b340fb198a773d14d01bcfbce271777` |
| `validation-arm64` | `465313de0156fc84004aa84cfda1f457e289b0c9a3433eb0bbbcdeff9ade3654` |

El log del job Android informa SHA256 del tarball `codex-arm64.tar.gz`:
`6e2f2e1127af95901b626dffaad10b27b61a5098badb289aa3eedb3ec73b3a01`.

La descarga del probe verificó su ZIP contra el digest de Actions antes de
extraerlo. El probe del run ejecutó correctamente 128 reemplazos de código en
Android aarch64/Termux y terminó con 0.

La descarga del ZIP Android verificó su SHA256 contra el digest de Actions y
el tarball extraído coincidió con el SHA256 del log del build, antes de extraer
y ejecutar binarios. Una interrupción de la transferencia se recuperó mediante
una petición HTTP Range; la verificación final cubrió el archivo completo.

El bundle extraído en un temporal de Termux reportó
`codex-cli 0.166.0+android2`. El smoke nativo del host devolvió:

```text
PASS: text(/a|b/.test("alpha"));
PASS: text(/[ab]/.test("alpha"));
```

Cada regex se ejecutó en una sesión sintética sin herramientas habilitadas,
con resultado final `true`, sin error de ejecución y salida del host con 0.
Esta prueba alcanza las dos reproducciones que causaban SIGSEGV en el build
instalado anterior. No acredita todos los flujos de Codex, MCP o uso prolongado.

No se instaló ni reemplazó la distribución vigente, no se modificó la
configuración del usuario y no se publicó una release. Los cambios ajenos de
OpenCode y los documentos temporales del checkout principal quedaron intactos.
