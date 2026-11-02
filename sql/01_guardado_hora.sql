-- Tabla PUTAWAY_HORA — Guardado por hora: unidades, volumen, peso, áreas, binfullness y tipo de reps
-- Nodo n8n: PEAK_PUTAWAY_HORA

CREATE OR REPLACE TABLE `your-project.analytics.PUTAWAY_HORA` AS

WITH

-- ══════════════════════════════════════════════════════════════════════════
-- 1. PRIMER DÍA DE OPERACIÓN POR REP
-- ══════════════════════════════════════════════════════════════════════════
first_day_pa AS (
  SELECT
    CAST(EMPLOYEE_ID AS STRING) AS OPERATOR_ID,
    MIN(FIRST_OPS_DAY) AS FIRST_DAY
  FROM `your-project.source.ATTENDANCE`
  WHERE FACILITY_ID = 'CD-01'
    AND SITE_ID = 'MLC'
    AND FIRST_OPS_DAY IS NOT NULL
  GROUP BY 1
),

-- ══════════════════════════════════════════════════════════════════════════
-- 2. PROCESO PRINCIPAL DE CADA REP
-- ══════════════════════════════════════════════════════════════════════════
PROCESO_PRINCIPAL AS (
  SELECT
    REP_ID,
    PROCESO_PRINCIPAL
  FROM (
    SELECT
      OPERATOR_ID AS REP_ID,
      PROCESS AS PROCESO_PRINCIPAL,
      SUM(COALESCE(PROCESS_DURATION, 0)) AS HH_PROCESO
    FROM `your-project.source.EMPLOYEE_ATTRIBUTES`
    WHERE LOGISTIC_CENTER_ID = 'CD-01'
      AND START_DATE >= DATE_SUB(
        CURRENT_DATE('America/Santiago'),
        INTERVAL 30 DAY
      )
      AND OPERATOR_ID IS NOT NULL
      AND PROCESS IN ('inbound', 'outbound')
    GROUP BY
      OPERATOR_ID,
      PROCESS
  )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY REP_ID
    ORDER BY HH_PROCESO DESC
  ) = 1
),

-- ══════════════════════════════════════════════════════════════════════════
-- 3. FLAG PART-TIME POR REP/DÍA
-- ══════════════════════════════════════════════════════════════════════════
ATT_PT AS (
  SELECT
    DATE(WORK_START_DATE) AS FECHA,
    CAST(USER_ID AS STRING) AS REP_ID,

    MAX(
      CASE
        WHEN REGEXP_CONTAINS(
          UPPER(COALESCE(SCHEDULE_NAME, '')),
          r'PTO'
        ) THEN 0

        WHEN REGEXP_CONTAINS(
          UPPER(COALESCE(SCHEDULE_NAME, '')),
          r'(^PT)|(\bPT\b)|(PT$)|(XDPT)|(PT[0-9])'
        )
        OR REGEXP_CONTAINS(
          UPPER(COALESCE(SCHEDULE_DESCRIPTION, '')),
          r'(^PT)|(\bPT\b)|(PT$)|(XDPT)|(PT[0-9])'
        ) THEN 1

        ELSE 0
      END
    ) AS IS_PT

  FROM `your-project.source.ATTENDANCE`

  WHERE SITE_ID = 'MLC'
    AND FACILITY_ID = 'CD-01'
    AND DATE(WORK_START_DATE) >= DATE_SUB(
      CURRENT_DATE('America/Santiago'),
      INTERVAL 30 DAY
    )
    AND DATE(WORK_START_DATE) <= CURRENT_DATE('America/Santiago')
    AND USER_ID IS NOT NULL

  GROUP BY
    FECHA,
    REP_ID
),

-- ══════════════════════════════════════════════════════════════════════════
-- 4. ACTIVIDAD POR HORA
-- ══════════════════════════════════════════════════════════════════════════
ACTIVIDAD_HORA AS (
  SELECT
    START_DATE AS FECHA,
    EXTRACT(HOUR FROM START_TIME) AS HORA,
    CAST(OPERATOR_ID AS STRING) AS REP_ID

  FROM `your-project.source.EMPLOYEE_ATTRIBUTES`

  WHERE LOGISTIC_CENTER_ID = 'CD-01'
    AND PROCESS = 'inbound'
    AND SUBPROCESS = 'putaway'
    AND START_DATE >= DATE_SUB(
      CURRENT_DATE('America/Santiago'),
      INTERVAL 30 DAY
    )
    AND START_DATE <= CURRENT_DATE('America/Santiago')
    AND OPERATOR_ID IS NOT NULL

  GROUP BY
    FECHA,
    HORA,
    CAST(OPERATOR_ID AS STRING)
),

-- ══════════════════════════════════════════════════════════════════════════
-- 5. CLASIFICACIÓN REP POR HORA
-- ══════════════════════════════════════════════════════════════════════════
REPS_CLASIFICADOS AS (
  SELECT
    r.FECHA,
    r.HORA,
    r.REP_ID AS OPERATOR_ID,

    CASE
      WHEN pp.PROCESO_PRINCIPAL = 'outbound' THEN 'PALANCA EXT'
      WHEN att.IS_PT = 1 THEN 'PT'

      ELSE
        CASE
          WHEN fd.FIRST_DAY IS NULL THEN 'NH1'

          WHEN DATE_DIFF(
            DATE_TRUNC(r.FECHA, WEEK(SUNDAY)),
            DATE_TRUNC(fd.FIRST_DAY, WEEK(SUNDAY)),
            WEEK
          ) = 0 THEN 'NH1'

          WHEN DATE_DIFF(
            DATE_TRUNC(r.FECHA, WEEK(SUNDAY)),
            DATE_TRUNC(fd.FIRST_DAY, WEEK(SUNDAY)),
            WEEK
          ) = 1 THEN 'NH2'

          WHEN DATE_DIFF(
            DATE_TRUNC(r.FECHA, WEEK(SUNDAY)),
            DATE_TRUNC(fd.FIRST_DAY, WEEK(SUNDAY)),
            WEEK
          ) = 2 THEN 'NH3'

          ELSE 'NATIVO'
        END
    END AS TIPO_REP

  FROM ACTIVIDAD_HORA r

  LEFT JOIN PROCESO_PRINCIPAL pp
    ON pp.REP_ID = r.REP_ID

  LEFT JOIN ATT_PT att
    ON att.REP_ID = r.REP_ID
   AND att.FECHA = r.FECHA

  LEFT JOIN first_day_pa fd
    ON fd.OPERATOR_ID = r.REP_ID
),

-- ══════════════════════════════════════════════════════════════════════════
-- 6. CONTEO DE REPS POR HORA
-- ══════════════════════════════════════════════════════════════════════════
REP_SHARE AS (
  SELECT
    FECHA,
    HORA,

    COUNT(*) AS TOTAL_REPS,

    COUNTIF(TIPO_REP = 'NH1') AS N_NH1,
    COUNTIF(TIPO_REP = 'NH2') AS N_NH2,
    COUNTIF(TIPO_REP = 'NH3') AS N_NH3,
    COUNTIF(TIPO_REP = 'NATIVO') AS N_NATIVO,
    COUNTIF(TIPO_REP = 'PT') AS N_PT,
    COUNTIF(TIPO_REP = 'PALANCA EXT') AS N_PALANCA_EXT,

    ROUND(
      SAFE_DIVIDE(COUNTIF(TIPO_REP = 'NH1'), COUNT(*)) * 100,
      1
    ) AS PCT_NH1,

    ROUND(
      SAFE_DIVIDE(COUNTIF(TIPO_REP = 'NH2'), COUNT(*)) * 100,
      1
    ) AS PCT_NH2,

    ROUND(
      SAFE_DIVIDE(COUNTIF(TIPO_REP = 'NH3'), COUNT(*)) * 100,
      1
    ) AS PCT_NH3,

    ROUND(
      SAFE_DIVIDE(COUNTIF(TIPO_REP = 'NATIVO'), COUNT(*)) * 100,
      1
    ) AS PCT_NATIVO,

    ROUND(
      SAFE_DIVIDE(COUNTIF(TIPO_REP = 'PT'), COUNT(*)) * 100,
      1
    ) AS PCT_PT,

    ROUND(
      SAFE_DIVIDE(COUNTIF(TIPO_REP = 'PALANCA EXT'), COUNT(*)) * 100,
      1
    ) AS PCT_PALANCA_EXT

  FROM REPS_CLASIFICADOS
  GROUP BY
    FECHA,
    HORA
),

-- ══════════════════════════════════════════════════════════════════════════
-- 7. CONTEO DE REPS ÚNICOS POR DÍA
-- ══════════════════════════════════════════════════════════════════════════
REP_DIA AS (
  SELECT
    FECHA,

    COUNT(DISTINCT OPERATOR_ID) AS TOTAL_REPS_DIA,

    COUNT(DISTINCT CASE
      WHEN TIPO_REP = 'NH1' THEN OPERATOR_ID
    END) AS N_NH1_DIA,

    COUNT(DISTINCT CASE
      WHEN TIPO_REP = 'NH2' THEN OPERATOR_ID
    END) AS N_NH2_DIA,

    COUNT(DISTINCT CASE
      WHEN TIPO_REP = 'NH3' THEN OPERATOR_ID
    END) AS N_NH3_DIA,

    COUNT(DISTINCT CASE
      WHEN TIPO_REP = 'NATIVO' THEN OPERATOR_ID
    END) AS N_NATIVO_DIA,

    COUNT(DISTINCT CASE
      WHEN TIPO_REP = 'PT' THEN OPERATOR_ID
    END) AS N_PT_DIA,

    COUNT(DISTINCT CASE
      WHEN TIPO_REP = 'PALANCA EXT' THEN OPERATOR_ID
    END) AS N_PALANCA_EXT_DIA,

    ROUND(
      SAFE_DIVIDE(
        COUNT(DISTINCT CASE
          WHEN TIPO_REP = 'NH1' THEN OPERATOR_ID
        END),
        COUNT(DISTINCT OPERATOR_ID)
      ) * 100,
      1
    ) AS PCT_NH1_DIA,

    ROUND(
      SAFE_DIVIDE(
        COUNT(DISTINCT CASE
          WHEN TIPO_REP = 'NH2' THEN OPERATOR_ID
        END),
        COUNT(DISTINCT OPERATOR_ID)
      ) * 100,
      1
    ) AS PCT_NH2_DIA,

    ROUND(
      SAFE_DIVIDE(
        COUNT(DISTINCT CASE
          WHEN TIPO_REP = 'NH3' THEN OPERATOR_ID
        END),
        COUNT(DISTINCT OPERATOR_ID)
      ) * 100,
      1
    ) AS PCT_NH3_DIA,

    ROUND(
      SAFE_DIVIDE(
        COUNT(DISTINCT CASE
          WHEN TIPO_REP = 'NATIVO' THEN OPERATOR_ID
        END),
        COUNT(DISTINCT OPERATOR_ID)
      ) * 100,
      1
    ) AS PCT_NATIVO_DIA,

    ROUND(
      SAFE_DIVIDE(
        COUNT(DISTINCT CASE
          WHEN TIPO_REP = 'PT' THEN OPERATOR_ID
        END),
        COUNT(DISTINCT OPERATOR_ID)
      ) * 100,
      1
    ) AS PCT_PT_DIA,

    ROUND(
      SAFE_DIVIDE(
        COUNT(DISTINCT CASE
          WHEN TIPO_REP = 'PALANCA EXT' THEN OPERATOR_ID
        END),
        COUNT(DISTINCT OPERATOR_ID)
      ) * 100,
      1
    ) AS PCT_PALANCA_EXT_DIA

  FROM REPS_CLASIFICADOS
  GROUP BY FECHA
),

-- ══════════════════════════════════════════════════════════════════════════
-- 8. CUBING
-- ══════════════════════════════════════════════════════════════════════════
CUBING AS (
  SELECT
    INVENTORY_ID,

    CASE
      WHEN FLAG_TOTABLE = TRUE
        OR TOTABILITY = 'TOTABLE'
      THEN TRUE
      ELSE FALSE
    END AS FLAG_TOTABLE,

    COALESCE(
      ITE_VOLUMEN,
      CASE
        WHEN ITE_HEIGHT > 0
         AND ITE_LENGTH > 0
         AND ITE_WIDTH > 0
        THEN ITE_HEIGHT * ITE_LENGTH * ITE_WIDTH / 1000.0
        ELSE NULL
      END
    ) AS VOL_LITROS,

    CASE
      WHEN ITE_VOLUMEN IS NOT NULL
       AND ITE_VOLUMEN > 0
      THEN 'ITE_VOLUMEN'

      WHEN ITE_HEIGHT > 0
       AND ITE_LENGTH > 0
       AND ITE_WIDTH > 0
      THEN 'CALCULADO'

      ELSE 'SIN_VOLUMETRIA'
    END AS FUENTE_VOLUMEN

  FROM `your-project.source.SKU_DETAILS`

  WHERE LOGISTIC_CENTER_ID = 'CD-01'
    AND SIT_SITE_ID = 'MLC'

  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY INVENTORY_ID
    ORDER BY
      (ITE_VOLUMEN IS NOT NULL) DESC,
      (ITE_HEIGHT IS NOT NULL) DESC
  ) = 1
),

-- ══════════════════════════════════════════════════════════════════════════
-- 9. UNIDADES POR HORA
-- ══════════════════════════════════════════════════════════════════════════
PROD_PA AS (
  SELECT
    START_DATE AS FECHA,
    EXTRACT(HOUR FROM START_TIME) AS HORA,

    CASE
      WHEN PD_AREA LIKE '%HV%' THEN 'HV3'
      WHEN PD_AREA = 'RK0' THEN 'RK0'
      WHEN PD_AREA LIKE '%RS%' THEN 'RS0'
      WHEN PD_AREA = 'MZ1' THEN 'MZ1'
      WHEN PD_AREA = 'MZ2' THEN 'MZ2'
      WHEN PD_AREA = 'MZ3' THEN 'MZ3'
      WHEN PD_AREA = 'MZ0' THEN 'MZ0'
      WHEN PD_AREA LIKE '%BL%' THEN 'BL0'
      ELSE 'OTHERS'
    END AS AREA,

    SUM(UNITS) AS UNIDADES

  FROM `your-project.source.EMPLOYEE_ATTRIBUTES`

  WHERE LOGISTIC_CENTER_ID = 'CD-01'
    AND SUBPROCESS = 'putaway'
    AND START_DATE >= DATE_SUB(
      CURRENT_DATE('America/Santiago'),
      INTERVAL 30 DAY
    )
    AND START_DATE <= CURRENT_DATE('America/Santiago')
    AND OPERATOR_ID IS NOT NULL

  GROUP BY
    FECHA,
    HORA,
    AREA
),

UND_PIVOTED AS (
  SELECT
    FECHA,
    HORA,

    SUM(UNIDADES) AS UND_TOTAL,
    SUM(CASE WHEN AREA = 'MZ0' THEN UNIDADES ELSE 0 END) AS UND_MZ0,
    SUM(CASE WHEN AREA = 'MZ1' THEN UNIDADES ELSE 0 END) AS UND_MZ1,
    SUM(CASE WHEN AREA = 'MZ2' THEN UNIDADES ELSE 0 END) AS UND_MZ2,
    SUM(CASE WHEN AREA = 'MZ3' THEN UNIDADES ELSE 0 END) AS UND_MZ3,
    SUM(CASE WHEN AREA = 'BL0' THEN UNIDADES ELSE 0 END) AS UND_BL,
    SUM(CASE WHEN AREA = 'HV3' THEN UNIDADES ELSE 0 END) AS UND_HV,
    SUM(CASE WHEN AREA = 'RS0' THEN UNIDADES ELSE 0 END) AS UND_RS,
    SUM(CASE WHEN AREA = 'OTHERS' THEN UNIDADES ELSE 0 END) AS UND_OTHERS

  FROM PROD_PA
  GROUP BY
    FECHA,
    HORA
),

-- ══════════════════════════════════════════════════════════════════════════
-- 10. MOVIMIENTOS PUT_AWAY
--     Corrección aplicada: +1 hora únicamente a FBM_CREATED_DATE
-- ══════════════════════════════════════════════════════════════════════════
MOVIMIENTOS_PA AS (
  SELECT
    DATE(
      DATETIME_ADD(m.FBM_CREATED_DATE, INTERVAL 1 HOUR)
    ) AS FECHA,

    EXTRACT(
      HOUR
      FROM DATETIME_ADD(m.FBM_CREATED_DATE, INTERVAL 1 HOUR)
    ) AS HORA,

    CASE
      WHEN m.ADDRESS_TO LIKE '%HV%' THEN 'HV3'
      WHEN m.ADDRESS_TO LIKE '%RK-0-1%' THEN 'HS'
      WHEN m.ADDRESS_TO LIKE '%RK-0-0%' THEN 'RK0'
      WHEN m.ADDRESS_TO LIKE '%RS%' THEN 'RS0'
      WHEN m.ADDRESS_TO LIKE '%MZ-1%' THEN 'MZ1'
      WHEN m.ADDRESS_TO LIKE '%MZ-2%' THEN 'MZ2'
      WHEN m.ADDRESS_TO LIKE '%MZ-3%' THEN 'MZ3'
      WHEN m.ADDRESS_TO LIKE '%MZ-0%' THEN 'MZ0'
      WHEN m.ADDRESS_TO LIKE '%BL%' THEN 'BL0'
      ELSE 'OTHERS'
    END AS AREA,

    CASE
      WHEN c.FLAG_TOTABLE IS TRUE THEN 'TOTEABLE'
      ELSE 'NO_TOTEABLE'
    END AS TIPO_TOTE,

    m.FBM_QUANTITY,

    m.FBM_QUANTITY * c.VOL_LITROS AS VOLUMEN_LITROS,

    CASE
      WHEN c.VOL_LITROS IS NOT NULL
      THEN m.FBM_QUANTITY
      ELSE 0
    END AS CANTIDAD_CON_VOL,

    CASE
      WHEN c.VOL_LITROS IS NULL
      THEN m.FBM_QUANTITY
      ELSE 0
    END AS CANTIDAD_SIN_VOL

  FROM `your-project.source.STOCK_MOVEMENTS` m

  LEFT JOIN CUBING c
    ON m.INVENTORY_ID = c.INVENTORY_ID

  WHERE m.WAREHOUSE_ID = 'CD-01'
    AND m.FBM_REASON_PROCESS = 'put_away'

    -- Filtro original de los últimos 30 días
    AND m.FBM_CREATED_DATE >= DATETIME_SUB(
      CURRENT_DATETIME(),
      INTERVAL 30 DAY
    )

    AND m.FBM_CREATED_DATE < CURRENT_DATETIME()

    AND m.FBM_QUANTITY > 0
),

-- ══════════════════════════════════════════════════════════════════════════
-- 11. PIVOT VOLUMETRÍA POR HORA
-- ══════════════════════════════════════════════════════════════════════════
VOL_PIVOTED AS (
  SELECT
    FECHA,
    HORA,

    SUM(
      CASE
        WHEN TIPO_TOTE = 'TOTEABLE'
        THEN FBM_QUANTITY
        ELSE 0
      END
    ) AS UND_TOTEABLE_BF,

    SUM(
      CASE
        WHEN TIPO_TOTE = 'NO_TOTEABLE'
        THEN FBM_QUANTITY
        ELSE 0
      END
    ) AS UND_NO_TOTEABLE_BF,

    SUM(CANTIDAD_SIN_VOL) AS UND_SIN_VOLUMEN,
    SUM(CANTIDAD_CON_VOL) AS UND_CON_VOLUMEN,
    SUM(VOLUMEN_LITROS) AS VOL_TOTAL_LITROS,

    SUM(
      CASE
        WHEN TIPO_TOTE = 'TOTEABLE'
        THEN VOLUMEN_LITROS
      END
    ) AS VOL_TOTEABLE_LITROS,

    SUM(
      CASE
        WHEN TIPO_TOTE = 'NO_TOTEABLE'
        THEN VOLUMEN_LITROS
      END
    ) AS VOL_NO_TOTEABLE_LITROS,

    SUM(CASE WHEN AREA = 'MZ0' THEN VOLUMEN_LITROS END) AS VOL_MZ0,
    SUM(CASE WHEN AREA = 'MZ1' THEN VOLUMEN_LITROS END) AS VOL_MZ1,
    SUM(CASE WHEN AREA = 'MZ2' THEN VOLUMEN_LITROS END) AS VOL_MZ2,
    SUM(CASE WHEN AREA = 'MZ3' THEN VOLUMEN_LITROS END) AS VOL_MZ3,
    SUM(CASE WHEN AREA = 'HS' THEN VOLUMEN_LITROS END) AS VOL_HS,
    SUM(CASE WHEN AREA = 'RK0' THEN VOLUMEN_LITROS END) AS VOL_RK,
    SUM(CASE WHEN AREA = 'BL0' THEN VOLUMEN_LITROS END) AS VOL_BL,
    SUM(CASE WHEN AREA = 'HV3' THEN VOLUMEN_LITROS END) AS VOL_HV,

    SUM(
      CASE
        WHEN AREA = 'HS'
        THEN FBM_QUANTITY
        ELSE 0
      END
    ) AS UND_HS_BF,

    SUM(
      CASE
        WHEN AREA = 'RK0'
        THEN FBM_QUANTITY
        ELSE 0
      END
    ) AS UND_RK_BF,

    SUM(
      CASE
        WHEN AREA = 'MZ0'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_MZ0,

    SUM(
      CASE
        WHEN AREA = 'MZ1'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_MZ1,

    SUM(
      CASE
        WHEN AREA = 'MZ2'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_MZ2,

    SUM(
      CASE
        WHEN AREA = 'MZ3'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_MZ3,

    SUM(
      CASE
        WHEN AREA = 'HS'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_HS,

    SUM(
      CASE
        WHEN AREA = 'RK0'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_RK,

    SUM(
      CASE
        WHEN AREA = 'BL0'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_BL,

    SUM(
      CASE
        WHEN AREA = 'HV3'
        THEN CANTIDAD_CON_VOL
        ELSE 0
      END
    ) AS UND_CON_VOL_HV

  FROM MOVIMIENTOS_PA
  GROUP BY
    FECHA,
    HORA
),

-- ══════════════════════════════════════════════════════════════════════════
-- 12. BINFULLNESS POR ÁREA
-- ══════════════════════════════════════════════════════════════════════════
BF_AREA AS (
  SELECT
    FBM_CURRENT_DATE AS BF_DATE,

    CASE
      WHEN DIRECCION LIKE '%HV%' THEN 'HV3'
      WHEN DIRECCION LIKE '%RK-0-0%' THEN 'RK0'
      WHEN DIRECCION LIKE '%RK-0-1%' THEN 'HS'
      WHEN DIRECCION LIKE '%RS%' THEN 'RS0'
      WHEN DIRECCION LIKE '%MZ-1%' THEN 'MZ1'
      WHEN DIRECCION LIKE '%MZ-2%' THEN 'MZ2'
      WHEN DIRECCION LIKE '%MZ-3%' THEN 'MZ3'
      WHEN DIRECCION LIKE '%MZ-0%' THEN 'MZ0'
      WHEN DIRECCION LIKE '%BL%' THEN 'BL0'
      ELSE 'OTHERS'
    END AS AREA,

    SAFE_DIVIDE(
      SUM(
        CASE
          WHEN TOTAL > 0 THEN
            CASE
              WHEN VOLUMEN_REAL > CAP_VOLUMEN_BIN_100
              THEN CAP_VOLUMEN_BIN_100
              ELSE VOLUMEN_REAL
            END
        END
      ),
      SUM(
        CASE
          WHEN TOTAL > 0 THEN
            CASE
              WHEN CAP_VOLUMEN_BIN_100 IS NULL
              THEN VOLUMEN_REAL
              ELSE CAP_VOLUMEN_BIN_100
            END
        END
      )
    ) AS RATIO_BIN

  FROM `your-project.source.BIN_CAPACITY_STOCK`

  WHERE PAIS = 'Chile'
    AND SITE = 'CD-01'
    AND NUMERO_SKU IS NOT NULL
    AND CAP_VOLUMEN_BIN_100 IS NOT NULL
    AND FBM_CURRENT_DATE >= DATE_SUB(
      CURRENT_DATE('America/Santiago'),
      INTERVAL 30 DAY
    )
    AND FBM_CURRENT_DATE <= CURRENT_DATE('America/Santiago')

  GROUP BY
    BF_DATE,
    AREA
),

BF_PIVOTED AS (
  SELECT
    BF_DATE,

    MAX(CASE WHEN AREA = 'MZ0' THEN RATIO_BIN END) AS BF_MZ0,
    MAX(CASE WHEN AREA = 'MZ1' THEN RATIO_BIN END) AS BF_MZ1,
    MAX(CASE WHEN AREA = 'MZ2' THEN RATIO_BIN END) AS BF_MZ2,
    MAX(CASE WHEN AREA = 'MZ3' THEN RATIO_BIN END) AS BF_MZ3,
    MAX(CASE WHEN AREA = 'HS' THEN RATIO_BIN END) AS BF_HS,
    MAX(CASE WHEN AREA = 'RK0' THEN RATIO_BIN END) AS BF_RK,
    MAX(CASE WHEN AREA = 'HV3' THEN RATIO_BIN END) AS BF_HV

  FROM BF_AREA
  GROUP BY BF_DATE
)

-- ══════════════════════════════════════════════════════════════════════════
-- SELECT FINAL
-- ══════════════════════════════════════════════════════════════════════════
SELECT
  rs.FECHA,
  rs.HORA,

  -- Reps por hora
  rs.TOTAL_REPS,
  rs.N_NH1,
  rs.N_NH2,
  rs.N_NH3,
  rs.N_NATIVO,
  rs.N_PT,
  rs.N_PALANCA_EXT,
  rs.PCT_NH1,
  rs.PCT_NH2,
  rs.PCT_NH3,
  rs.PCT_NATIVO,
  rs.PCT_PT,
  rs.PCT_PALANCA_EXT,

  -- Reps únicos por día
  rd.TOTAL_REPS_DIA,
  rd.N_NH1_DIA,
  rd.N_NH2_DIA,
  rd.N_NH3_DIA,
  rd.N_NATIVO_DIA,
  rd.N_PT_DIA,
  rd.N_PALANCA_EXT_DIA,
  rd.PCT_NH1_DIA,
  rd.PCT_NH2_DIA,
  rd.PCT_NH3_DIA,
  rd.PCT_NATIVO_DIA,
  rd.PCT_PT_DIA,
  rd.PCT_PALANCA_EXT_DIA,

  -- Unidades desde DM_PRODUCTIVITY
  COALESCE(u.UND_TOTAL, 0) AS UND_TOTAL,
  COALESCE(u.UND_MZ0, 0) AS UND_MZ0,
  COALESCE(u.UND_MZ1, 0) AS UND_MZ1,
  COALESCE(u.UND_MZ2, 0) AS UND_MZ2,
  COALESCE(u.UND_MZ3, 0) AS UND_MZ3,
  COALESCE(v.UND_HS_BF, 0) AS UND_HS,
  COALESCE(v.UND_RK_BF, 0) AS UND_RK,
  COALESCE(u.UND_BL, 0) AS UND_BL,
  COALESCE(u.UND_HV, 0) AS UND_HV,
  COALESCE(u.UND_RS, 0) AS UND_RS,
  COALESCE(u.UND_OTHERS, 0) AS UND_OTHERS,

  -- Unidades toteable / no toteable
  COALESCE(v.UND_TOTEABLE_BF, 0) AS UND_TOTEABLE,
  COALESCE(v.UND_NO_TOTEABLE_BF, 0) AS UND_NO_TOTEABLE,

  -- Diagnóstico volumétrico
  COALESCE(v.UND_SIN_VOLUMEN, 0) AS UND_SIN_VOLUMEN,

  ROUND(
    SAFE_DIVIDE(
      v.UND_CON_VOLUMEN,
      v.UND_CON_VOLUMEN + v.UND_SIN_VOLUMEN
    ) * 100,
    1
  ) AS PCT_COBERTURA_VOL,

  -- Porcentaje toteable / no toteable
  ROUND(
    SAFE_DIVIDE(
      v.UND_TOTEABLE_BF,
      v.UND_TOTEABLE_BF + v.UND_NO_TOTEABLE_BF
    ) * 100,
    1
  ) AS PCT_TOTEABLE,

  ROUND(
    SAFE_DIVIDE(
      v.UND_NO_TOTEABLE_BF,
      v.UND_TOTEABLE_BF + v.UND_NO_TOTEABLE_BF
    ) * 100,
    1
  ) AS PCT_NO_TOTEABLE,

  -- Shares por área
  ROUND(SAFE_DIVIDE(u.UND_MZ0, u.UND_TOTAL) * 100, 1) AS SHR_MZ0,
  ROUND(SAFE_DIVIDE(u.UND_MZ1, u.UND_TOTAL) * 100, 1) AS SHR_MZ1,
  ROUND(SAFE_DIVIDE(u.UND_MZ2, u.UND_TOTAL) * 100, 1) AS SHR_MZ2,
  ROUND(SAFE_DIVIDE(u.UND_MZ3, u.UND_TOTAL) * 100, 1) AS SHR_MZ3,
  ROUND(SAFE_DIVIDE(v.UND_HS_BF, u.UND_TOTAL) * 100, 1) AS SHR_HS,
  ROUND(SAFE_DIVIDE(v.UND_RK_BF, u.UND_TOTAL) * 100, 1) AS SHR_RK,
  ROUND(SAFE_DIVIDE(u.UND_BL, u.UND_TOTAL) * 100, 1) AS SHR_BL,
  ROUND(SAFE_DIVIDE(u.UND_HV, u.UND_TOTAL) * 100, 1) AS SHR_HV,
  ROUND(SAFE_DIVIDE(u.UND_RS, u.UND_TOTAL) * 100, 1) AS SHR_RS,
  ROUND(SAFE_DIVIDE(u.UND_OTHERS, u.UND_TOTAL) * 100, 1) AS SHR_OTHERS,

  -- Volúmenes totales
  ROUND(v.VOL_TOTAL_LITROS, 1) AS VOL_TOTAL_LITROS,
  ROUND(v.VOL_TOTEABLE_LITROS, 1) AS VOL_TOTEABLE_LITROS,
  ROUND(v.VOL_NO_TOTEABLE_LITROS, 1) AS VOL_NO_TOTEABLE_LITROS,

  -- Volúmenes por área
  ROUND(v.VOL_MZ0, 1) AS VOL_MZ0,
  ROUND(v.VOL_MZ1, 1) AS VOL_MZ1,
  ROUND(v.VOL_MZ2, 1) AS VOL_MZ2,
  ROUND(v.VOL_MZ3, 1) AS VOL_MZ3,
  ROUND(v.VOL_HS, 1) AS VOL_HS,
  ROUND(v.VOL_RK, 1) AS VOL_RK,
  ROUND(v.VOL_BL, 1) AS VOL_BL,
  ROUND(v.VOL_HV, 1) AS VOL_HV,

  -- Volumen por unidad según tipo
  ROUND(
    SAFE_DIVIDE(v.VOL_TOTEABLE_LITROS, u.UND_TOTAL),
    2
  ) AS VOL_X_UND_TOTEABLE,

  ROUND(
    SAFE_DIVIDE(v.VOL_NO_TOTEABLE_LITROS, u.UND_TOTAL),
    2
  ) AS VOL_X_UND_NO_TOTEABLE,

  -- Volumen por unidad según área
  ROUND(SAFE_DIVIDE(v.VOL_MZ0, u.UND_MZ0), 2) AS VOL_X_UND_MZ0,
  ROUND(SAFE_DIVIDE(v.VOL_MZ1, u.UND_MZ1), 2) AS VOL_X_UND_MZ1,
  ROUND(SAFE_DIVIDE(v.VOL_MZ2, u.UND_MZ2), 2) AS VOL_X_UND_MZ2,
  ROUND(SAFE_DIVIDE(v.VOL_MZ3, u.UND_MZ3), 2) AS VOL_X_UND_MZ3,
  ROUND(SAFE_DIVIDE(v.VOL_HS, v.UND_HS_BF), 2) AS VOL_X_UND_HS,
  ROUND(SAFE_DIVIDE(v.VOL_RK, v.UND_RK_BF), 2) AS VOL_X_UND_RK,
  ROUND(SAFE_DIVIDE(v.VOL_BL, u.UND_BL), 2) AS VOL_X_UND_BL,
  ROUND(SAFE_DIVIDE(v.VOL_HV, u.UND_HV), 2) AS VOL_X_UND_HV,

  -- Promedio ponderado total
  ROUND(
    SAFE_DIVIDE(v.VOL_TOTAL_LITROS, u.UND_TOTAL),
    2
  ) AS VOL_X_UND_PONDERADO,

  -- Binfullness por área
  ROUND(COALESCE(bf.BF_MZ0, 0) * 100, 1) AS BF_MZ0,
  ROUND(COALESCE(bf.BF_MZ1, 0) * 100, 1) AS BF_MZ1,
  ROUND(COALESCE(bf.BF_MZ2, 0) * 100, 1) AS BF_MZ2,
  ROUND(COALESCE(bf.BF_MZ3, 0) * 100, 1) AS BF_MZ3,
  ROUND(COALESCE(bf.BF_HS, 0) * 100, 1) AS BF_HS,
  ROUND(COALESCE(bf.BF_RK, 0) * 100, 1) AS BF_RK,
  ROUND(COALESCE(bf.BF_HV, 0) * 100, 1) AS BF_HV

FROM REP_SHARE rs

LEFT JOIN REP_DIA rd
  ON rd.FECHA = rs.FECHA

LEFT JOIN UND_PIVOTED u
  ON u.FECHA = rs.FECHA
 AND u.HORA = rs.HORA

LEFT JOIN VOL_PIVOTED v
  ON v.FECHA = rs.FECHA
 AND v.HORA = rs.HORA

LEFT JOIN BF_PIVOTED bf
  ON bf.BF_DATE = rs.FECHA

ORDER BY
  rs.FECHA DESC,
  rs.HORA DESC;
