# Qué aprovechar de Devin Desktop en Pio Pio

15 de noviembre de 2026. Revisión de las dos aplicaciones instaladas en el Mac y contraste con el código de Pio Pio. En Devin recorrí una sesión local existente, su actividad, el inicio de sesión de trabajo y las seis secciones de la barra lateral. En Pio Pio recorrí Inicio, el proyecto, sus ajustes y una conversación anterior. La evaluación cubre la experiencia de uso. La calidad de las respuestas, la ejecución en la nube y las integraciones externas quedan fuera de lo probado.

## 1. Poder investigar qué hizo el agente

En una sesión real de Pio Pio, el inspector mostraba **«2 files · 146 commands ›»**. El destino de ese control es Archivos. Quien pulsa sobre «146 commands» tiene una pregunta distinta de quien pulsa sobre «2 files». Puede querer saber si se ejecutaron las pruebas, cuál falló o qué ocurrió después.

Devin ofrece dos niveles de detalle. En la conversación, una línea con el tiempo de trabajo se despliega para mostrar los pasos de ese turno. En el panel **Progress**, los eventos de la sesión se pueden buscar y filtrar por tipo o estado. Al seleccionar un evento hay espacio para su detalle. Pio Pio ya tiene el primer nivel, con el comando, su salida y el código de error cuando corresponde. [Registro de actividad actual](../design/activity/README.md)

**Primera entrega.** Dividir la fila del inspector en dos destinos. «2 archivos» abre los archivos que tocó el agente. «146 comandos» abre la actividad de la conversación, filtrada a comandos. Añadir búsqueda por texto y un filtro «Fallidos». Cada resultado debe permitir leer su salida y saltar al turno correspondiente. En una ventana estrecha, esa lista puede ocupar el inspector y conservar la posición de lectura al volver.

**Prueba de uso.** En una sesión larga que incluya un fallo, pedir a alguien que encuentre el último comando de prueba fallido, lea su salida y vuelva al mensaje que lo originó. Observar si puede hacerlo sin recorrer el chat. [Inspector actual](../../apps/mac/App/Piopio/Inspector.swift)

## 2. Decir por qué hace falta intervenir

Devin mostraba **Approval required** bajo el título de la sesión y repetía el aviso dentro del chat. Eso permitía reconocer el bloqueo desde otra pantalla. Al abrir la sesión, el comando que motivaba el permiso estaba dentro del historial plegado, mientras el contador «Working for» seguía avanzando. Un contador de espera que parece tiempo de trabajo puede dar la impresión de que el agente sigue progresando.

Pio Pio ya ordena las sesiones activas, marca las que esperan aprobación y tiene tarjetas de decisión. En Inicio vi siete asuntos pendientes y varias preguntas de redacción parecida del mismo agente. El contador indicaba volumen. Para decidir qué atender hacía falta leer las filas. [Barra lateral](../../apps/mac/App/Piopio/MainSidebar.swift) · [Tarjetas de decisión](../../apps/mac/App/Piopio/BuildViews.swift)

**Cambio propuesto.** Cuando haya que actuar, añadir una segunda línea temporal bajo la sesión, por ejemplo «Permiso para ejecutar pruebas» si la acción se conoce, o «Revisar comando» como alternativa fiel. Al pulsar, llevar el foco a la tarjeta que muestra la operación real. En Inicio, agrupar preguntas parecidas por agente y conservar cada pregunta y su respuesta por separado. Un fallo de ejecución debe seguir teniendo su propia fila y acción.

**Prueba de uso.** Con dos sesiones activas y una esperando permiso, comprobar si se reconoce desde la barra lateral cuál necesita atención y si una sola selección muestra exactamente qué se va a autorizar.

## 3. Hacer que una rutina empiece por un resultado

En **Automations**, Devin presenta ejemplos como preparar un resumen semanal de cambios o investigar un fallo de integración continua. Cada tarjeta explica qué inicia el trabajo, qué hará el agente y dónde aparecerá el resultado. También identifica las integraciones. En esta cuenta las tarjetas de ejemplo aparecían deshabilitadas. Evalué su presentación.

El formulario de rutinas de proyecto de Pio Pio ya admite horario, archivo en una carpeta, correo y webhook. Al crear una rutina hay que elegir uno y redactar el encargo. Además, Pio Pio ya usa plantillas al crear agentes. Llevar ese patrón al formulario de rutinas permite probar la idea con capacidades actuales. [Formulario de rutinas](../../apps/mac/App/Piopio/TeamViews.swift) · [Plantillas de agentes](../../apps/mac/App/Piopio/StartView.swift)

| Plantilla para probar | Disparador | Resultado visible en el proyecto |
| --- | --- | --- |
| Resumen semanal del repositorio | Viernes a la hora elegida | Una conversación con los cambios de la semana y referencias a los commits |
| Resumir un informe nuevo | Aparece un archivo en la carpeta elegida | Una conversación con la síntesis y el nombre del archivo |
| Preparar la respuesta a un correo | Llega un correo que coincide con el filtro | Un borrador en la conversación para que el usuario lo revise |

La tarjeta prellenaría el formulario actual. Antes de guardar se verían el proyecto, el disparador y el resultado esperado. Empezaría por el resumen semanal, que se puede probar con un repositorio local.

## Otras decisiones de interfaz y producto

| Superficie observada en Devin | Aplicación a Pio Pio |
| --- | --- |
| Navegación a la izquierda, conversación en el centro, herramienta a la derecha. La pestaña vacía ocupaba alrededor de un tercio de la ventana. | Mantener el inspector bajo demanda. Abrirlo con contenido concreto al pulsar un comando, un archivo o un cambio. Reservar el espacio central para leer y escribir. |
| El inicio reúne Local/Cloud, carpeta, agente y modo. La cabecera de la sesión existente decía «Piopio», aunque su actividad mostraba que exploraba la carpeta personal de agentes. | Mostrar la ruta abreviada al elegir entre carpetas de nombre parecido. En este Mac, `~/Piopio` y `~/Proyectos/piopio` conducen a trabajos distintos. Es un detalle pequeño con más valor inmediato que añadir un selector de nube. |
| Durante el trabajo, el compositor ofrece guiar al agente o dejar un mensaje en cola. Cada mensaje ofrece también bifurcar o volver a ese punto. | Pio Pio ya ofrece cola, intervención inmediata, bifurcación y retroceso. Su cola permite editar y retirar mensajes. Conservar sus atajos y comprobar que ambos tipos de envío se entienden mientras hay texto escrito. [Compositor](../../apps/mac/App/Piopio/Composer.swift) |
| Review acepta la URL de una petición de cambios. Wiki mostraba un estado vacío que invitaba a conectar Git. | Aplazar una bandeja de revisiones remotas hasta que revisar trabajo ajeno sea frecuente. Para trabajo local, Pio Pio ya tiene diffs y commits. Para orientarse en un proyecto, sus instrucciones y notas compartidas ya ofrecen un punto de partida. [Inspector y cambios](../design/inspector/as-built.md) |
| Customizations distingue lo instalado para la persona o para el equipo y reúne plugins, skills, MCP, reglas y memoria. | Aprovechar la indicación de alcance. En el inspector se podría explicar si una herramienta procede de los ajustes personales o del proyecto y si está activa en esa conversación. Daría prioridad a esa información sobre ampliar el catálogo. |
| Apps Beta ofrece crear y servir aplicaciones para la organización. Security presenta escaneos y hallazgos por gravedad. | Ambas áreas requieren operación continuada y un público que gestione despliegues o varios repositorios. Para la versión personal de Pio Pio, invertir primero en completar y revisar el trabajo local. |

**Orden de prueba.** Primero el acceso desde «146 comandos» a la actividad filtrada. Después, la etiqueta de intervención y el salto a la decisión. Por último, una plantilla de rutina que se pueda crear y verificar de principio a fin con datos locales. Las tres propuestas caben en pantallas que el usuario ya conoce.
