-- Lecturas que se unen (Merge) y se publican al dashboard
-- Nodo n8n: PEAK_PUTAWAY + PEAK_CHECKIN + PEAK_DCI

-- Nodo PEAK_PUTAWAY
SELECT 'PUTAWAY' AS PROCESO, * 
FROM `your-project.analytics.PUTAWAY_HORA` 
ORDER BY FECHA, HORA


-- Nodo PEAK_CHECKIN
SELECT 'CHECKIN' AS PROCESO, * 
FROM `your-project.analytics.CHECKIN_HORA` 
ORDER BY FECHA, HORA


-- Nodo PEAK_DCI
SELECT 'DCI' AS PROCESO, * 
FROM `your-project.analytics.DCI_HORA` 
ORDER BY FECHA, HORA
