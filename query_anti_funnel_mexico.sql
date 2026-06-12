 -- ============================================================================
-- ANTI-FUNNEL: Lead Status & Rejection Reasons Analysis — México 2026
-- ============================================================================
-- Purpose: Identify WHERE leads get stuck and WHY they're not qualifying
-- Dimensions: Fuente × Sub-fuente × Plataforma × Campaña × Razón Rechazo
-- Focus: Lead status tracking only (NO spend/investment data)
-- Periods: Hoy / Ayer / Últimos 7d / Última semana / Último mes / Personalizado
-- ============================================================================

DECLARE fecha_inicio DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY);
DECLARE fecha_fin DATE DEFAULT DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY);

-- ============================================================================
-- CTEs: Build the rejection reason taxonomy & lead journey
-- ============================================================================

WITH lead_universe AS (
  -- All leads from configured sources, exclude today (incomplete data)
  SELECT
    CAST(g.fecha_creacion AS DATE) AS fecha_creacion,
    CAST(g.fecha_a_pricing AS DATE) AS fecha_pricing,
    g.nid,
    g.fuente,
    g.area_metropolitana,
    g.id_ultimo_estado AS last_estado_id,
    
    -- Estado final: if Cierre, look up actual estado from deals; else use g.estado
    CASE
      WHEN g.estado = 'Cierre' THEN COALESCE(d.estado, g.estado)
      ELSE g.estado
    END AS estado_final,
    
    -- Sub-fuente (mkt_channel_medium): Paid / Direct / Leadform / etc
    CASE
      WHEN g.campana_mercadeo IS NULL AND g.fuente = 'Lead Forms' THEN 'Leadform Paid'
      WHEN g.campana_mercadeo = '' AND g.fuente = 'Lead Forms' THEN 'Leadform Paid'
      WHEN g.campana_mercadeo IS NULL OR g.campana_mercadeo = '' THEN CONCAT(g.fuente, ' Direct')
      WHEN m.mkt_channel_medium IS NULL OR m.mkt_channel_medium = '' THEN g.campana_mercadeo
      ELSE m.mkt_channel_medium
    END AS mkt_channel_medium,
    
    -- Plataforma (extracted from UTM table)
    COALESCE(m.mkt_platform, 'Sin plataforma') AS plataforma,
    
    -- Campaña (normalizada)
    COALESCE(m.campana_mercadeo_original, g.campana_mercadeo, 'Sin campaña') AS campana,
    
  FROM `papyrus-data-mx.habi_wh_bi.tabla_inmuebles_general` AS g
  LEFT JOIN `sellers-main-prod.bi_mx.registro_unico_utm_mkt_mexico` AS m 
    ON g.campana_mercadeo = m.campana_mercadeo_original
  LEFT JOIN `sellers-main-prod.hubspot.deals` AS d 
    ON d.nid = g.nid
    
  WHERE 1=1
    AND g.fuente IN ('WEB', 'Estudio Inmueble', 'Lead Forms', 'Broker', 'Comercial', 'Propiedades')
    AND g.fecha_creacion >= fecha_inicio
    AND g.fecha_creacion <= fecha_fin
),

-- ============================================================================
-- Mapeo de razones de rechazo basado en estado_id
-- ============================================================================
rejection_mapping AS (
  SELECT
    l.*,
    CASE
      -- Estado 1 = Duplicado
      WHEN l.last_estado_id = 1 THEN 'Duplicado'
      
      -- Estado 3 = Fuera de zona
      WHEN l.last_estado_id = 3 THEN 'Fuera de zona'
      
      -- Estado 7 = Incompleto
      WHEN l.last_estado_id = 7 THEN 'Datos incompletos'
      
      -- Estado 10 = Precio elevado
      WHEN l.last_estado_id = 10 THEN 'Precio elevado'
      
      -- Estado 16 = Antigüedad (propiedad muy vieja)
      WHEN l.last_estado_id = 16 THEN 'Antigüedad propiedad'
      
      -- Estado 33 = Revisar dirección
      WHEN l.last_estado_id = 33 THEN 'Datos de dirección inválidos'
      
      -- Estado 38 = Inmueble no habi
      WHEN l.last_estado_id = 38 THEN 'Inmueble no elegible'
      
      -- Estado 55 = Tipo propiedad no aplica
      WHEN l.last_estado_id = 55 THEN 'Tipo propiedad no elegible'
      
      -- Estado 56 = Zona restringida
      WHEN l.last_estado_id = 56 THEN 'Zona restringida'
      
      -- Estados de calificación: 20 (no_gestionado), 63 (sin_pricing_inicial)
      WHEN l.last_estado_id IN (20, 63) THEN 'Calificado'
      
      -- Estados pendientes/en proceso
      WHEN l.last_estado_id IN (2, 4, 5, 6, 8, 9, 11, 12, 13, 14, 15) THEN 'Pendiente'
      
      -- Catch-all para estados desconocidos
      ELSE CONCAT('Otro (estado_id: ', CAST(l.last_estado_id AS STRING), ')')
    END AS razon_rechazo,
    
    CASE
      WHEN l.last_estado_id IN (20, 63) THEN 'Calificado'
      WHEN l.last_estado_id IN (1, 3, 7, 10, 16, 33, 38, 55, 56, 61, 64) THEN 'Rechazado'
      ELSE 'Pendiente'
    END AS estado_categorizado,
    
  FROM lead_universe l
),

-- ============================================================================
-- Agregación por período: resumen ejecutivo
-- ============================================================================
resumen_ejecutivo AS (
  SELECT
    COUNT(*) AS total_creados,
    SUM(CASE WHEN estado_categorizado = 'Calificado' THEN 1 ELSE 0 END) AS total_calificados,
    SUM(CASE WHEN estado_categorizado = 'Rechazado' THEN 1 ELSE 0 END) AS total_rechazados,
    SUM(CASE WHEN estado_categorizado = 'Pendiente' THEN 1 ELSE 0 END) AS total_pendientes,
    ROUND(
      100.0 * SUM(CASE WHEN estado_categorizado = 'Calificado' THEN 1 ELSE 0 END) / 
      NULLIF(COUNT(*), 0), 2
    ) AS pct_calificados
  FROM rejection_mapping
),

-- ============================================================================
-- Desglose por Fuente × Sub-fuente
-- ============================================================================
desglose_fuente_subfuente AS (
  SELECT
    fuente,
    mkt_channel_medium,
    COUNT(*) AS creados,
    SUM(CASE WHEN estado_categorizado = 'Calificado' THEN 1 ELSE 0 END) AS calificados,
    SUM(CASE WHEN estado_categorizado = 'Rechazado' THEN 1 ELSE 0 END) AS rechazados,
    ROUND(100.0 * SUM(CASE WHEN estado_categorizado = 'Calificado' THEN 1 ELSE 0 END) / 
          NULLIF(COUNT(*), 0), 2) AS pct_calificados,
    
    -- Top razón de rechazo (usando ANY_VALUE)
    ANY_VALUE(razon_rechazo) AS top_razon_rechazo
    
  FROM rejection_mapping
  GROUP BY fuente, mkt_channel_medium
  ORDER BY creados DESC
),

-- ============================================================================
-- Distribución de razones de rechazo
-- ============================================================================
razon_rechazo_dist AS (
  SELECT
    razon_rechazo,
    COUNT(*) AS cantidad,
    ROUND(100.0 * COUNT(*) / 
          (SELECT COUNT(*) FROM rejection_mapping WHERE estado_categorizado = 'Rechazado'), 2) AS pct_rechazados
  FROM rejection_mapping
  WHERE estado_categorizado = 'Rechazado'
  GROUP BY razon_rechazo
  ORDER BY cantidad DESC
),

-- ============================================================================
-- Análisis granular: Fuente × Sub-fuente × Plataforma × Campaña
-- ============================================================================
analisis_granular AS (
  SELECT
    fuente,
    mkt_channel_medium,
    plataforma,
    campana,
    COUNT(*) AS creados,
    SUM(CASE WHEN estado_categorizado = 'Calificado' THEN 1 ELSE 0 END) AS calificados,
    SUM(CASE WHEN estado_categorizado = 'Rechazado' THEN 1 ELSE 0 END) AS rechazados,
    ROUND(100.0 * SUM(CASE WHEN estado_categorizado = 'Calificado' THEN 1 ELSE 0 END) / 
          NULLIF(COUNT(*), 0), 2) AS pct_calificados,
    
    -- Top razón de rechazo en este segmento (usando ANY_VALUE)
    ANY_VALUE(razon_rechazo) AS top_razon_rechazo
    
  FROM rejection_mapping
  GROUP BY fuente, mkt_channel_medium, plataforma, campana
  ORDER BY creados DESC
)

-- ============================================================================
-- FINAL OUTPUT: Tablas de exportación
-- ============================================================================

-- 1. RESUMEN EJECUTIVO
SELECT 
  'Resumen Ejecutivo' AS seccion,
  'N/A' AS fuente,
  'N/A' AS mkt_channel_medium,
  total_creados AS creados,
  total_calificados AS calificados,
  total_rechazados AS rechazados,
  pct_calificados,
  'N/A' AS top_razon_rechazo
FROM resumen_ejecutivo
UNION ALL

-- 2. RAZONES DE RECHAZO (Top 10)
SELECT 
  'Razones Rechazo' AS seccion,
  razon_rechazo AS fuente,
  'N/A' AS mkt_channel_medium,
  cantidad AS creados,
  0 AS calificados,
  cantidad AS rechazados,
  pct_rechazados AS pct_calificados,
  razon_rechazo AS top_razon_rechazo
FROM razon_rechazo_dist
UNION ALL

-- 3. DESGLOSE FUENTE × SUB-FUENTE
SELECT 
  'Fuente × Sub-fuente' AS seccion,
  fuente,
  mkt_channel_medium,
  creados,
  calificados,
  rechazados,
  pct_calificados,
  top_razon_rechazo
FROM desglose_fuente_subfuente
UNION ALL

-- 4. ANÁLISIS GRANULAR
SELECT 
  'Análisis Granular' AS seccion,
  fuente,
  mkt_channel_medium,
  creados,
  calificados,
  rechazados,
  pct_calificados,
  top_razon_rechazo
FROM analisis_granular
WHERE plataforma != 'Sin plataforma'
ORDER BY seccion, creados DESC;
