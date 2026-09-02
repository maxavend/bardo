# Task 1 — Informe

## Cambios

- Añadido `ManagedModel` con los cinco modelos gestionados y `ManagedModelState` con estados equatables y sendable.
- Añadido `BardoModelStore` con raíz live en `Application Support/Bardo/Models`, raíces privadas por modelo y `reset(_:)` limitado al hijo seleccionado.
- La eliminación valida tanto la relación de hijo directo como la ruta resuelta de symlinks; rechaza una raíz que escape del almacenamiento privado.
- Actualizado `project.yml` para incluir `Bardo/Models` explícitamente en XcodeGen sin duplicar sus fuentes.
- Añadidas pruebas de aislamiento de rutas, exclusión de la ruta global de FluidAudio, reset selectivo, rechazo de symlink externo y contratos de estado.

## Pruebas

- `xcodegen generate` — correcto.
- Ciclo RED: el comando focal del brief llegó a compilar y falló con los símbolos ausentes `ManagedModel` y `ManagedModelState`.
- Comando focal GREEN:

  ```text
  xcodebuild test -project Bardo.xcodeproj -scheme Bardo -destination 'platform=macOS,arch=arm64' -only-testing:BardoTests/BardoModelStoreTests -only-testing:BardoTests/ManagedModelStateTests CODE_SIGNING_ALLOWED=NO
  ```

  Resultado: `TEST SUCCEEDED`; 6 pruebas ejecutadas, 0 fallos.

Las pruebas crean sus raíces bajo `FileManager.default.temporaryDirectory`; no llaman a `BardoModelStore.live()`, no descargan modelos y no mutan cachés de modelos del usuario.

## Limitaciones

- Esta tarea define el límite de ownership y los contratos; los managers/adapters existentes todavía no se migran a estas raíces, porque pertenecen a tareas posteriores.
- No se ejecutó la suite completa; la verificación fue el foco solicitado por el brief.
- Xcode emitió advertencias del entorno macOS sobre servicios auxiliares (`linkd`/CoreSimulator), sin afectar el resultado de las seis pruebas originales.

## Fix de revisión

- Causa: la validación anterior resolvía el root inyectado y aceptaba un `Bardo/Models` symlinked si sus hijos estaban bajo la ubicación externa resuelta; `reset` podía borrar ese hijo externo.
- Cambio: `BardoModelStore.live()` y `reset(_:)` ahora rechazan cualquier raíz privada que resuelva mediante symlink. La validación se ejecuta antes de inspeccionar o eliminar el modelo seleccionado.
- Prueba añadida: `testResetRejectsAnInjectedRootThatIsAnExternalSymlink` crea `Models -> external-model-cache`, verifica el error `invalidPrivateRoot` y confirma que el archivo externo sobrevive.
- Reproducción previa: el mismo foco fallaba con 2 aserciones en 7 pruebas; no lanzaba error y eliminaba el marcador bajo el root externo symlinked.
- Comando:

  ```text
  xcodebuild test -project Bardo.xcodeproj -scheme Bardo -destination 'platform=macOS,arch=arm64' -only-testing:BardoTests/BardoModelStoreTests -only-testing:BardoTests/ManagedModelStateTests CODE_SIGNING_ALLOWED=NO
  ```

  Resultado: `TEST SUCCEEDED`; 7 pruebas ejecutadas, 0 fallos.
