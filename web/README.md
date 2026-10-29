# Web de Bardo

Sitio estático con Astro, Tailwind y componentes Base UI/shadcn. React se hidrata únicamente en la demostración del hero, cuando es visible. El fondo WebGL y el control para compartir son elementos nativos; las otras tres páginas no cargan React. No hay servicios externos de fuentes, analítica, formularios ni grabación de audio en esta web.

## Desarrollo y comprobaciones

Requiere la versión de Node indicada en `package.json`.

```sh
npm ci
npm run dev
npm run typecheck
npm run lint
npm test
npm run build
npm run check:build
npm audit
npm run preview
```

`check:build` valida los hashes de scripts y estilos contra la CSP generada, los archivos locales enlazados, la ausencia de handlers inline y el presupuesto de hidratación. `test` comprueba compartir, cancelar y las alternativas cuando falta un permiso o una API. Revisar la CSP con `build` y `preview`: Astro no la aplica en el servidor de desarrollo.

Los componentes existentes están en `src/components/ui`; para añadir otro puede usarse `npx shadcn@latest add nombre`. La CLI no es una dependencia del sitio.

## Versiones y descargas

Al compilar, `src/lib/site.ts` lee los releases publicados de GitHub (sin borradores ni prereleases) y ofrece el más reciente que trae `Bardo-<versión>.dmg`, y el más reciente que trae ambos instaladores de Windows (`Bardo-<versión>-Setup-x64.exe` y `-arm64.exe`, que adjunta el flujo Release). Los enlaces, la versión y la fecha del footer salen de ahí, así que el sitio debe compilarse de nuevo después de cada release: el flujo `Website` (`.github/workflows/website.yml`) se lo pide a Cloudflare Pages al publicarse uno. Si GitHub no responde, el build avisa y usa el release fijo de `fallback` en el mismo archivo. Con `GITHUB_TOKEN` en el entorno, la consulta no cuenta contra el límite anónimo.

Mientras ningún release trae instaladores de Windows, el sitio ofrece solo Mac, muestra Windows como «Pronto» y la portada no tiene la sección «También en Windows.». Para revisar cómo se verá, sin publicarlo:

```sh
PUBLIC_WINDOWS_RELEASE=1.2.0 npm run dev
```

El botón de descarga pregunta al navegador qué equipo es (`src/scripts/platform.ts`, con pruebas en `scripts/platform.test.mjs`): Edge y Chrome distinguen Windows ARM de x64; los demás navegadores de Windows reciben x64, que Windows en ARM también ejecuta.

## Rendimiento y accesibilidad

- Fuentes WOFF2 locales de subconjunto latino, con precarga y `font-display: swap`.
- Capturas WebP con fuentes específicas para móvil, dimensiones reservadas, carga diferida y decodificación asíncrona.
- El fondo tiene un buffer de resolución reducida y un máximo de 60 dibujos por segundo. La onda limita el DPR a 2 y reutiliza máscaras. Ambas animaciones duermen fuera de pantalla y con la pestaña oculta.
- El cambio de Reducir movimiento se respeta en vivo. La transcripción revela por opacidad, sin filtros de desenfoque por palabra.
- El enlace móvil usa el origen y la ruta actuales. Cancelar el panel de compartir no modifica el portapapeles. Si copiar falla, ofrece una URL seleccionable.

Revisión local de producción, 28 de octubre de 2026: las cuatro rutas se comprobaron a 320, 390, 640, 768, 1024 y 1440 px, sin texto ni controles recortados, ni referencias `aria-labelledby` inexistentes. Se verificaron visualmente el hero, las capturas, el cierre y el footer. Esto no sustituye pruebas en dispositivos físicos ni mediciones de campo.

## Publicación y seguridad

Publicar **solo `dist/`**. Astro genera una CSP por meta con hashes para los scripts/estilos, recursos del mismo origen y bloqueo de objetos, marcos, formularios y handlers inline. Se permiten atributos de estilo para los retardos y las máscaras de la demostración, sin permitir scripts inline arbitrarios ni `eval`.

`public/_headers` añade protección contra inclusión en marcos, restricciones de permisos, `nosniff`, política de referrer y caché inmutable de un año **solo para `/_astro/*`**, cuyos nombres incluyen hashes. Los archivos públicos sin hash y el HTML pueden cambiar en cada publicación.

**El hosting debe admitir `_headers`**, como [Cloudflare Pages](https://developers.cloudflare.com/pages/configuration/headers/); en otro servicio hay que trasladar las reglas a su configuración. `astro preview` no aplica ese archivo. La protección [`frame-ancestors`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/frame-ancestors) requiere una cabecera HTTP y no funciona desde meta.

Al confirmar dominio y hosting, comprobar las cabeceras de las respuestas reales, HTTPS y compresión Brotli/gzip. Configurar entonces la URL `site` de Astro para futuras URLs canónicas. No se ha configurado HSTS para un dominio desconocido. La auditoría local no mide CDN, TTFB público ni Core Web Vitals reales; esas mediciones quedan para el despliegue.

## Publicar en Cloudflare Pages

El sitio se publica como un proyecto de Pages conectado a GitHub, que compila `main`:

| Ajuste | Valor |
|---|---|
| Repositorio y rama de producción | `maxavend/bardo`, `main` |
| Directorio raíz | `web` |
| Comando de compilación | `npm run build && npm run check:build` |
| Directorio de salida | `dist` |
| Variable `NODE_VERSION` | `24` (`package.json` pide 22.23.4 o posterior) |
| Variable `GITHUB_TOKEN` | Opcional: un token *fine-grained* sin permisos, solo para no depender del límite anónimo de la API |
| Rutas observadas (*build watch paths*) | Incluir `web/*`, para que los cambios solo de la app no publiquen la web |

Pages instala las dependencias desde `package-lock.json` antes de compilar. Si el registro dice `Could not read the releases`, el sitio salió con el release de `fallback`: revisar la red o el token y compilar otra vez.

Para que cada release publicado actualice las descargas, crear un *Deploy Hook* de la rama `main` en el proyecto de Pages y guardarlo como secreto `CLOUDFLARE_PAGES_DEPLOY_HOOK` del repositorio. El flujo `Website` también se puede lanzar a mano desde Actions.

Con el dominio definido, añadir `site` en `astro.config.mjs` y comprobar en producción: las cabeceras de `_headers` en `/` y en un archivo de `/_astro/`, HTTPS, la compresión, y que los enlaces de descarga de la portada y de `/descargar` respondan.

