# Leads "recuperados" por apertura de zona (MX) — diagnóstico

**País:** MX · **Fecha diagnóstico:** 2026-07-21/22 · **Autor:** Leonardo Herrera

---

## TL;DR
Los ~495 leads que aparecían "recuperados por apertura de zona" y que **parecían no asignarse** en la tabla del WBR **no son un bug de asignación ni de captura**. Es un **efecto de medición**: la recuperación de Backbone re-tipifica el *estado* de leads que en su mayoría **ya habían sido calificados y asignados ~100 días antes** (ciclo ene–abr). Como esos leads ya tenían su fila en el mart de primera asignación, la re-activación **no genera asignación nueva ni bump en el tablero**.

---

## El síntoma
- En la tabla del WBR aparecían ~495 leads recuperados (Backbone re-evaluó leads que estaban en `fuera_de_la_zona`).
- 240 de ellos figuraban con estado **"No gestionado"** → parecían leads sin asignar.
- Expectativa: esos leads deberían avanzar a asignación y verse como un aumento de asignados en el WBR. No se veía.

## Qué encontramos

**1. "No gestionado" ≠ "sin asignar".**
Es la tipificación del Backbone (estado 20 = calificado), no gestión comercial. Validando los 240:
- 0 sin deal en HubSpot · 0 sin owner (ninguno huérfano)
- **219/239 (92%) ya tenían el evento `Primer asignacion`** en el funnel
- El 8% restante = lag de materialización

**2. La mayoría ya estaba asignada desde el primer ciclo.**
- **204/240 (85%) ya estaban asignados ~100 días antes** (ene–abr), ya contados en el WBR de entonces.
- Solo 17 (7%) generaron asignación nueva ahora.
- 19 (8%) nunca entraron al mart → único grupo con algo real que revisar.

**3. Por qué no hay bump en el tablero.**
El tablero usa el **mart de primera asignación (1 fila por lead)**. Una re-activación de un lead ya asignado no crea fila nueva → conserva la fecha vieja → no aparece aumento esta semana. Antes "sí se veía" porque Backbone recuperaba leads que nunca se habían asignado (esa sí era su primera asignación).

**4. Causa raíz: evento de zona de Querétaro.**
- Querétaro aportó **290/302 (96%)** de los recuperados, siendo solo ~5% de la base MX (19× sobre-representado). Valle de México (54.5% de la base) aportó solo 7.
- Ciclo: zona abierta → leads califican y se asignan (~100 días antes) → zona cierra → caen a `fuera_de_la_zona` → zona reabre → Backbone re-tipifica a calificado = "recuperados".

## El mecanismo (por qué Backbone los "ofrece de nuevo")
Estado y asignación viven en sistemas distintos y se movieron por separado:
- Al **cerrar** la zona, se sobreescribió el **estado** a `fuera_de_la_zona`, pero **el owner/asignación en HubSpot no se borró**. Las dos dimensiones se desacoplaron.
- Al **reabrir**, Backbone solo restaura el **estado**.

Hipótesis de la lógica de Backbone (a confirmar con el equipo): la recuperación **evalúa el `state_id` actual, no el historial del lead**. Barre todo lo que está en `fuera_de_la_zona` y, si la zona reabre, lo re-califica — sin preguntarse si ese lead ya había sido calificado/asignado/descartado en un ciclo previo. Por eso lo presenta como "oportunidad" aunque ya haya pasado por el funnel: no deduplica contra su propia trayectoria.

## ⚠️ Pendiente — pregunta abierta a Backbone
> Cuando se reabre una zona, la lógica de recuperación de Backbone ¿evalúa únicamente el `state_id` actual (`fuera_de_la_zona`), o consulta el historial del lead para detectar que ya había sido calificado/asignado/descartado en un ciclo previo? Es decir, ¿un lead que ya pasó por el funnel se vuelve a ofrecer como oportunidad de recuperación, o debería excluirse por su historial?

- Si responden **"solo mira el estado actual, es esperado"** → no hay bug en Backbone; la corrección es de **medición** (no contar re-tipificaciones como recuperaciones netas).
- Si responden **"debería excluir por historial"** → hay un **bug real** de deduplicación en Backbone.

## Conclusiones y acciones
- **No hay bug de asignación ni de captura.** El fenómeno es de medición + evento puntual de Querétaro.
- **Medición:** no leer `state_id = No gestionado` como "sin asignar". Verificar asignación real con **owner HubSpot + evento `Primer asignacion`** del funnel.
- **Lo único real a revisar:** los **19 leads** que nunca entraron al mart.
- **Pricing:** los 63 en `Sin pricing inicial` + `Sin datos para comparar` son efecto esperado de zona nueva sin comparables → acción de pricing, no de asignación.
- Los descartado/incompleto/sin-pricing es correcto que no se asignen.

## Regla para la próxima vez
Si reaparece "leads recuperados que no se asignan / no aparecen en el WBR":
1. Verificar asignación con **owner + evento del funnel**, nunca con la columna de estado.
2. Comparar **fecha de asignación del mart vs fecha de recuperación**: si la asignación es vieja, ya se contó y la "recuperación" es solo cambio de estado.
3. Para medir re-activaciones hace falta una **métrica aparte** del equipo del mart (el actual es de primera asignación, 1 fila/lead).

---

### Notas técnicas (reproducción)
- Reconstruir el set con el **historial de estados**, no con `id_ultimo_estado` (el estado actual matchea toda la base).
- Set = `deal_id` con fila `state_id = fuera_de_zona` en `sellers-main-prod.mx_rds_staging.habi_db_history_state` (MM; Inmo = `...habi_db_history_state_real_estate`) que luego tiene fila `state_id IN (20,63)` reciente.
- Join `h.deal_id = tig.id_negocio` a `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general`, group by `area_metropolitana`.
- Tablero WBR: join a `papyrus-master.sellers_data_mart.sellers_leads_asignados_marketing_wbr_mart` (campo `asi.dia`).
- Conflicto a confirmar: `estado_id` de `fuera_de_zona` = 10 según doc BQ, pero la query anti-funnel del repo `tablero-mx-lead-status` usa 3.
