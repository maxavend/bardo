# Task 3 — Informe

## Resultado

Implementada la selección de modelos WhisperKit y la abstracción de backend/preset para que Task 4 pueda conectar Parakeet sin redefinir contratos. Balanced sigue siendo la selección predeterminada y usa WhisperKit large-v3 Turbo; Maximum Accuracy usa WhisperKit large-v3.

## Cambios

- `Bardo/Transcription/TranscriptionBackend.swift`
  - Añade `TranscriptionBackend` con `.parakeet` y `.whisperKit`.
  - Añade `TranscriptionPreset` con `.instant`, `.balanced` y `.maximumAccuracy`.
  - Añade `TranscriptionSelection`, con Codable para conservarla en persistencia.
- `Bardo/Transcription/TranscriptionModelManager.swift`
  - Añade `TranscriptionModelDefinition` y el catálogo de las dos variantes WhisperKit existentes:
    - `large-v3-v20240930_turbo_632MB` — WhisperKit large-v3 Turbo — default Balanced.
    - `large-v3-v20240930_626MB` — WhisperKit large-v3 — Maximum Accuracy.
  - El initializer recibe una definición; `selectedDefinition()` y `selectedSelection()` exponen la selección efectiva.
  - El preflight usa `requiredFreeBytes` de la definición y mantiene el umbral existente de 1.500.000.000 bytes para ambas variantes.
  - `live()` deriva la raíz desde `BardoModelStore` usando `.whisperBalanced`/`.whisperMaximumAccuracy`; no accede ni duplica raíces globales de WhisperKit/FluidAudio.
  - Expone `ManagedModelState` mediante `state()` y actualiza estados/progreso durante preparación, descarga, cache hit y error.
  - Conserva el cache de recursos/tokenizer por la vida del manager y la preparación existente de tokenizer large-v3.
- `Bardo/Transcription/WhisperTranscriptionService.swift`
  - Mantiene exactamente la firma de `RecordingTranscribing`.
  - Propaga la selección WhisperKit al transcript generado sin cambiar la planificación, carga, callbacks ni caching del pipeline.
- `Bardo/Domain/Transcript.swift`
  - Añade `TranscriptMetadata.selection` opcional.
  - La decodificación acepta documentos existentes que no tienen ese campo; la selección nueva se conserva mediante Codable.
- Tests:
  - Amplía `TranscriptionModelManagerTests` con IDs/display names del catálogo, default Balanced, Maximum Accuracy, estado final, progreso y caching.
  - Añade `TranscriptionBackendTests` para los casos de backend/preset y round-trip Codable de metadata de selección.

No se modificaron `BardoModelStore`, `ManagedModelState` ni `ModelRecoveryPolicy`; se reutilizan los contratos de Tasks 1–2. La lógica de recuperación destructiva de caché permanece fuera de esta task, para las tareas de adapters específicas del plan.

## Verificación TDD

1. Línea base focal: `TranscriptionModelManagerTests` + `TranscriptionPipelineTests` — 14 tests, 0 fallos.
2. RED: después de añadir los tests de Task 3 y regenerar XcodeGen, la compilación falló por los símbolos ausentes `TranscriptionBackend`, `TranscriptionPreset`, `TranscriptionSelection`, `TranscriptionModelDefinition` y el argumento `TranscriptMetadata.selection`.
3. GREEN focal inicial: 11 tests, 0 fallos.
4. Foco final de Task 3:

   ```text
   xcodebuild test -project Bardo.xcodeproj -scheme Bardo -destination 'platform=macOS,arch=arm64' \
     -only-testing:BardoTests/TranscriptionModelManagerTests \
     -only-testing:BardoTests/TranscriptionBackendTests \
     -only-testing:BardoTests/TranscriptionPipelineTests CODE_SIGNING_ALLOWED=NO
   ```

   Resultado: 20 tests, 0 fallos.
5. Suite completa:

   ```text
   xcodebuild test -project Bardo.xcodeproj -scheme Bardo -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
   ```

   Resultado: 131 tests, 0 fallos; `** TEST SUCCEEDED **`.
6. `git diff --check` — sin errores.

XcodeGen regeneró `Bardo.xcodeproj` y `Bardo/Info.plist`; ambos son artefactos ignorados según `.gitignore`. Los tests no descargan modelos ni acceden a la red: usan raíces temporales y skeletons locales.

## Evidencia y limitaciones

- La primera ejecución de XcodeBuild fue bloqueada por el sandbox al escribir en `~/.cache/clang/ModuleCache` y `~/Library/Caches/org.swift.swiftpm`; las ejecuciones posteriores se hicieron con autorización elevada y compilaron correctamente.
- Xcode emitió advertencias del entorno sobre CoreSimulator, `linkd`, CoreMedia y audio; no cambiaron el resultado de los 131 tests.
- Esta task no implementa el adapter Parakeet ni modifica dependencias: la abstracción queda disponible para Task 4, que será responsable de FluidAudio.
- No se probó una transcripción real ni una descarga de WhisperKit; las pruebas de esta task son deliberadamente offline.
- Los DMG `Bardo-Phase7-Test.dmg` y `.sha256` ya estaban sin seguimiento y se conservaron sin modificaciones.
