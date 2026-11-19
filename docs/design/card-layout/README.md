# Handoff: Layout con chat en tarjeta

## Overview
Rediseño del layout principal de la app (macOS). Se sustituye la línea divisoria entre sidebar y contenido por una **tarjeta** que contiene el chat, flotando sobre el fondo de la ventana. Los paneles laterales derechos (Summary, Archivos) van **planos sobre el fondo**, simétricos al sidebar. El **Navegador** es la excepción: va en su propia tarjeta.

## About the Design Files
`Layout Final.dc.html` es una **referencia de diseño en HTML** (ábrela en un navegador; necesita `support.js` al lado). No es código de producción. La tarea es recrear este diseño en el entorno existente de la app (SwiftUI/AppKit u otro) con sus patrones y componentes.

## Fidelity
**High-fidelity** para estructura, colores, radios, sombras y espaciado. Iconos son placeholders (formas simples) — usar los iconos actuales de la app (SF Symbols). Tipografía: fuente del sistema (SF Pro).

## Screens / Views
El archivo muestra 4 estados (F1–F4) de la misma ventana.

### Estructura común
```
Window (bg #F4F4F2, radius 12)
├── Sidebar  236px fijo, padding 14/8/10, sin borde ni fondo propio
└── Content area (flex)
    ├── Chat card   margin 8px (top/right/bottom; 0 a la izquierda — el sidebar da el aire)
    └── Right panel (opcional)
```

### Chat card
- Fondo `#FCFCFB`, radius `10px`
- Sombra: `0 0 0 1px rgba(0,0,0,.06), 0 1px 3px rgba(0,0,0,.05)` (hairline + elevación mínima; la separación depende del hairline porque el contraste de fondo es muy bajo)
- Header 48px: título 13px semibold, meta "Chat · 4 minutes ago" 13px `#999`, acciones a la derecha (botones 28×28 radius 7; activo con fondo `#EDEDEC`)
- Columna de mensajes: max-width 520px centrada, padding lateral 32px, texto 14px / line-height 1.6, color `#262625`
- Burbuja de usuario: fondo `#EDEDEC`, radius 14, padding 10×14, alineada a la derecha
- Caja de respuesta: fondo `#FFFFFF` (blanco puro, se eleva sobre la tarjeta), radius 14, sombra `0 0 0 1px rgba(0,0,0,.09), 0 4px 14px rgba(0,0,0,.05)`, padding 12×14, margen inferior 18px

### Sidebar
- Items: 13px, padding 6×8, radius 7, gap 10 entre icono y texto
- Item seleccionado: fondo `rgba(0,0,0,.065)`
- Títulos de sección: 12px `#8A8A86`, padding-top 16
- Avatar 26px, fondo `#E5E5E3`

### F1 — Sin panel
Sidebar + chat card ocupando todo el ancho restante.

### F2 — Panel Summary (plano)
- Ancho 252px, **sin fondo ni sombra** (comparte `#F4F4F2` con la ventana). Chat card pierde el margen derecho (margin-right 0); el panel tiene padding horizontal 8px.
- Título "Summary" 13px semibold, alto 56px
- Secciones Context / Setup: label 12px `#8A8A86`; grid 56px | 1fr, gap 6–8px
- Footer "Cost  $0.49" anclado abajo

### F3 — Panel Archivos (plano)
- Ancho 280px, sin fondo ni sombra
- Campo filtro: alto 32, radius 8, fondo `#E9E9E6` (un punto más oscuro que la ventana para que se lea), placeholder `#A2A29E`, atajo "⌘P"
- Segmented All / Touched: fondo `#E9E9E6`, padding 2, radius 8; segmento activo `#FFFFFF` radius 6 sombra `0 1px 2px rgba(0,0,0,.08)`
- Cabecera proyecto: "piopio" / "~/Proyectos" 12px `#8A8A86`
- Filas: 13px, padding 5×10, radius 6; seleccionada `rgba(0,0,0,.055)`; badge a la derecha 11px semibold — N `#2E9D57`, M `#D9822B`, R `#2F6FD6`
- Leyenda "N new · M changed · R read" 12px
- Footer separado con `border-top: 1px solid rgba(0,0,0,.06)`: barra de contexto (44×4) + "120k of 1M" + coste

### F4 — Panel Navegador (tarjeta)
- Ancho 440px, **tarjeta** con el mismo estilo que el chat card (`#FCFCFB`, radius 10, misma sombra). Gap 8px con el chat card; ventana margin 8px.
- Toolbar 48px: atrás / adelante / recargar, barra URL (alto 30, radius 8, fondo `#F1F1EF`, 12px), menú •••, cerrar ×
- Viewport web inset: margin 0 8px 8px, radius 7, hairline `0 0 0 1px rgba(0,0,0,.06)`

## Interactions & Behavior
- Los botones del header del chat abren/cierran el panel derecho (uno a la vez). El botón activo lleva fondo `#EDEDEC`.
- Al abrir un panel plano (Summary/Archivos) el chat card se estrecha; sugerido animar el ancho ~200ms ease-out.
- Navegador: al ser tarjeta, puede animarse entrando desde la derecha con opacidad.
- Hover en items de sidebar/árbol: `rgba(0,0,0,.04)`.

## State Management
- `rightPanel: 'none' | 'summary' | 'files' | 'browser'`
- Archivos: `filter: string`, `scope: 'all' | 'touched'`, nodo seleccionado/expandidos
- Navegador: URL, historial (back/forward)

## Design Tokens
Colores
- Ventana / sidebar / paneles planos: `#F4F4F2`
- Tarjeta (chat, navegador): `#FCFCFB`
- Input de respuesta: `#FFFFFF`
- Superficie sutil (burbuja usuario, botón activo): `#EDEDEC`
- Campos sobre fondo de ventana: `#E9E9E6`
- Campos dentro de tarjeta: `#F1F1EF`
- Avatar: `#E5E5E3`
- Texto: `#262625`; secundario `#8A8A86`; terciario/placeholder `#A2A29E`
- Selección: `rgba(0,0,0,.065)` sidebar, `rgba(0,0,0,.055)` árbol
- Hairline: `rgba(0,0,0,.06)`

Radios: ventana 12 · tarjeta 10 · input respuesta 14 · campos 8 · items 6–7

Sombras
- Tarjeta: `0 0 0 1px rgba(0,0,0,.06), 0 1px 3px rgba(0,0,0,.05)`
- Input respuesta: `0 0 0 1px rgba(0,0,0,.09), 0 4px 14px rgba(0,0,0,.05)`

Espaciado: margen de tarjeta 8 · gap entre tarjetas 8 · sidebar 236 · Summary 252 · Archivos 280 · Navegador 440

Tipografía (SF Pro): 13px UI · 14px/1.6 mensajes · 12px labels/meta · 11px badges

## Assets
Ninguno. Iconos son placeholders — usar SF Symbols existentes. El contenido de Hacker News en F4 es ilustrativo.

## Files
- `Layout Final.dc.html` — los 4 estados (F1–F4); abrir en navegador junto a `support.js`
