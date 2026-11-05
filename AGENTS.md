# ai-cli-termux

Instalador de CLIs para Termux con overlay glibc o binarios nativos. Conservá el pipeline genérico y fail-closed.

- Comportamiento por herramienta: registry/<tool>.conf, WRAPPER_ENV o hooks. No agregar condicionales por tool en install.sh si lo resuelve un hook. aicli orquesta: no duplica instalación ni verificación.
- Nunca instalar sin checksum verificado. release_digest/manifest pueden resolver versión y digest; sha256.txt es pin opcional allí y fuente obligatoria en hashfile. No omitir verify.sh.
- EXEC_DIRECT=true requiere NEEDS_PATCHELF=false y binario compatible nativo; el overlay glibc no vuelve compatible cualquier binario Linux. Conservar contrato de EXTRA_BINS.
- Builds Android propios: source oficial pineado, gates de integridad y compilación, dist separado con digest/attestation. Revisiones usan +androidN y se comparan por tag del manifest; no simplificar a solo núcleo semver.
- --resolve-version imprime únicamente TARGET_VERSION=<v> en stdout, preserva +build, logs a stderr; sin instalación ni efectos persistentes. Argumentos incompatibles: exit 2. aicli list degrada fallos de red a n/d sin fallar el listado.
- aicli: 0 éxito / 1 ejecución / 2 uso; help/version stdout; errores stderr. Respetar NO_COLOR, TERM=dumb y no-TTY. No sobrescribir wrapper aicli sin marca aicli-managed. DESCRIPTION en .conf es una línea, sin comillas internas.
- Hooks son código del instalador: revisar y ejecutar shellcheck antes de probar.

## Comprobaciones

- Leer archivos pertinentes y ejecutar `shellcheck install.sh verify.sh aicli registry/lib/*.sh registry/opencode.conf` según el alcance. No ejecutar install.sh como si fuera una prueba sin efectos.
- Una instalación/reinstalación/actualización requiere autorización de ese alcance. Si no se hace, declarar la integración no ejecutada; no afirmar que instalar/verificar pasó.
- Uso: bash install.sh <tool> [-v X.Y.Z | --update | -r | -u]; bash verify.sh <tool> verifica la instalación existente. No ejecutar por costumbre todas las variantes.
- Arquitectura, campos y detalles del pipeline: [referencia técnica](.agent-notes/20261026.md), README.md y docs/adr/. Consultar los contratos pertinentes antes de tocarlos. Archivos históricos no prevalecen sobre código y evidencia actual.

Las decisiones y los contratos técnicos de `.agent-notes/20261026.md` siguen formando parte de las reglas del proyecto: consultá la sección pertinente antes de modificar ese subsistema. Los conteos de tests, estados de avance y permisos históricos requieren verificación actual y no sustituyen estas reglas ni la política global vigente.

- Preferí construcciones POSIX portables; no agregues funciones exclusivas de Bash 4+ sin una razón fuerte ni dependencias nuevas sin justificación y compatibilidad Termux.
