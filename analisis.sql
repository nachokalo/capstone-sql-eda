-- =====================================================================
-- Proyecto Capstone: Análisis Exploratorio de Datos en PostgreSQL
-- analisis.sql - Limpieza y consultas de análisis
-- Ignacio Kalogiannidis - PostgreSQL 16
-- =====================================================================
--
-- Ejecución, en este orden:
--   psql -d capstone_project -f estructura.sql
--   psql -d capstone_project -f analisis.sql
--
-- Dos partes y un cierre: la primera perfila y limpia, la segunda
-- responde las seis preguntas de negocio y el cierre resume el resultado.
-- No modifica ninguna tabla, solo lee y crea una vista.


-- #####################################################################
-- PARTE 1. PERFILADO Y LIMPIEZA
-- #####################################################################
-- Todo lo que sigue parte de una idea: un NULL no es un cero. El cero
-- afirma que la venta fue de cero pesos; el NULL admite que no sabemos
-- cuánto fue. Confundirlos hunde promedios y totales, así que cada hueco
-- se trata por separado y con un criterio declarado.


-- ---------------------------------------------------------------------
-- 1.1. Los tipos de dato son los correctos
-- ---------------------------------------------------------------------
-- Se revisa antes de analizar: un tipo mal elegido obliga a convertir en
-- cada consulta y abre la puerta a errores de redondeo y de orden.
SELECT table_name  AS tabla,
       column_name AS columna,
       data_type   AS tipo_declarado
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('clientes','productos','pedidos')
  AND (data_type IN ('date','numeric'))
ORDER BY table_name, ordinal_position;


-- ---------------------------------------------------------------------
-- 1.2. Cuánto hueco hay y dónde
-- ---------------------------------------------------------------------
-- Se mide antes de decidir nada: no es lo mismo que el problema afecte
-- al uno por ciento de las filas que al treinta.
SELECT count(*) AS pedidos_totales,
       count(*) FILTER (WHERE precio_unitario IS NULL) AS sin_precio_unitario,
       round(100.0 * count(*) FILTER (WHERE precio_unitario IS NULL)
             / count(*), 1) AS pct_sin_precio,
       count(*) FILTER (WHERE fecha_pedido IS NULL) AS sin_fecha,
       round(100.0 * count(*) FILTER (WHERE fecha_pedido IS NULL)
             / count(*), 1) AS pct_sin_fecha
FROM pedidos;

-- Los pedidos sin ninguna fuente de precio van a quedar fuera de los
-- totales de facturación, así que hay que saber si el hueco está
-- repartido o concentrado. Si cayera todo en una categoría, la
-- comparación entre categorías quedaría sesgada sin que se note.
SELECT pr.categoria,
       count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NULL) AS sin_ninguna_fuente,
       count(*)                                        AS pedidos_de_la_categoria,
       round(100.0 * count(*) FILTER (WHERE p.precio_unitario IS NULL
                                        AND pr.precio_lista IS NULL)
             / count(*), 1)                            AS pct
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id
GROUP BY pr.categoria
ORDER BY pr.categoria;

-- El hueco de precio tiene dos gravedades: una se puede reparar con el
-- precio de lista del producto y la otra no tiene de dónde salir.
SELECT count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NOT NULL) AS recuperables_con_lista,
       count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NULL)     AS sin_ninguna_fuente,
       -- El peso de lo irrecuperable marca cuánto de piso tiene el
       -- número final, y va al pie de cualquier informe de facturación.
       round(100.0 * count(*) FILTER (WHERE p.precio_unitario IS NULL
                                        AND pr.precio_lista IS NULL)
             / (SELECT count(*) FROM pedidos), 1)           AS pct_irrecuperable
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id
WHERE p.precio_unitario IS NULL;


-- ---------------------------------------------------------------------
-- 1.3. La vista limpia, base de todo el análisis
-- ---------------------------------------------------------------------
-- La limpieza se resuelve en un solo lugar para que las seis consultas
-- partan del mismo criterio. Si cada una limpiara por su cuenta,
-- alcanzaría con que a una se le escapara el COALESCE para que los
-- totales del informe dejaran de cerrar entre sí.
--
-- Precio: cuando el pedido no trae importe se usa el precio de lista del
-- producto. Cuando tampoco hay precio de lista, el importe queda en NULL:
-- la venta se cuenta como unidad movida, pero taparla con un cero sería
-- afirmar que se regaló.
--
-- Fecha: no se imputa. Nada en la fila permite estimarla, y una fecha
-- inventada contamina la serie temporal sin dejar rastro. El NULL se
-- conserva y se etiqueta más abajo.
CREATE OR REPLACE VIEW ventas_limpias AS
SELECT
    p.pedido_id,
    p.cliente_id,
    p.producto_id,
    pr.categoria,
    p.canal,
    p.cantidad,
    p.fecha_pedido,
    p.cantidad * COALESCE(p.precio_unitario, pr.precio_lista) AS importe,
    -- Deja rastro de qué filas tienen el precio completado, por si hace
    -- falta un número auditado que las excluya.
    CASE WHEN p.precio_unitario IS NULL AND pr.precio_lista IS NOT NULL
              THEN 'Completado con precio de lista'
         WHEN p.precio_unitario IS NULL AND pr.precio_lista IS NULL
              THEN 'Sin precio disponible'
         ELSE 'Precio original'
    END AS origen_del_precio,
    -- COALESCE sobre la fecha ya convertida a período. No inventa la
    -- fecha: vuelve visible su ausencia como una categoría más.
    COALESCE(TO_CHAR(p.fecha_pedido, 'YYYY-MM'), 'Sin fecha') AS periodo
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id;

-- Qué aportó la limpieza. La facturación de los pedidos sin precio queda
-- vacía y no en cero: esas ventas movieron mercadería, así que sus
-- unidades se cuentan, pero no se les puede asignar un importe.
SELECT origen_del_precio,
       count(*)       AS pedidos,
       sum(cantidad)  AS unidades,
       sum(importe)   AS facturacion
FROM ventas_limpias
GROUP BY origen_del_precio
ORDER BY sum(importe) DESC NULLS LAST;

-- El número que justifica haber hecho la limpieza: lo que se habría
-- perdido dejando los nulos afuera de la suma en lugar de completarlos.
SELECT sum(cantidad * precio_unitario)                       AS sin_limpiar,
       (SELECT sum(importe) FROM ventas_limpias)             AS con_limpieza,
       (SELECT sum(importe) FROM ventas_limpias)
           - sum(cantidad * precio_unitario)                 AS diferencia
FROM pedidos;


-- ---------------------------------------------------------------------
-- 1.4. Control de integridad del JOIN
-- ---------------------------------------------------------------------
-- Es el error más silencioso del análisis: si la clave del lado derecho
-- no fuera única, cada fila se duplicaría y todos los totales quedarían
-- inflados sin que nada falle. El conteo antes y después tiene que dar
-- igual.
-- Se controlan los tres cruces que usa el análisis, y no solo el
-- primero: si el argumento vale para uno, vale para todos.
WITH controles AS (
    SELECT 'pedidos con productos'          AS cruce,
           (SELECT count(*) FROM pedidos)   AS antes,
           (SELECT count(*) FROM ventas_limpias) AS despues
    UNION ALL
    SELECT 'ventas con clientes',
           (SELECT count(*) FROM ventas_limpias),
           (SELECT count(*) FROM ventas_limpias v
                            JOIN clientes c ON c.cliente_id = v.cliente_id)
    UNION ALL
    SELECT 'ventas con productos, para el ranking',
           (SELECT count(*) FROM ventas_limpias),
           (SELECT count(*) FROM ventas_limpias v
                            JOIN productos pr ON pr.producto_id = v.producto_id)
)
SELECT cruce,
       antes AS filas_antes_del_join,
       despues AS filas_despues_del_join,
       CASE WHEN antes = despues THEN 'OK, no multiplicó filas'
            ELSE 'ALERTA, revisar la cardinalidad de la clave'
       END AS control
FROM controles;


-- #####################################################################
-- PARTE 2. SEIS PREGUNTAS DE NEGOCIO
-- #####################################################################


-- ---------------------------------------------------------------------
-- PREGUNTA 1. Quiénes son los cinco clientes que más facturan
-- ---------------------------------------------------------------------
-- Tal como la pide la consigna: gasto total por cliente con GROUP BY y
-- SUM, y los cinco primeros. El orden lo da la facturación: un cliente de
-- muchas compras chicas vale menos que uno de pocas compras grandes.
SELECT c.cliente_id,
       c.nombre,
       sum(v.importe) AS gasto_total
FROM ventas_limpias v
JOIN clientes c ON c.cliente_id = v.cliente_id
GROUP BY c.cliente_id, c.nombre
ORDER BY gasto_total DESC NULLS LAST, c.cliente_id
LIMIT 5;

-- La misma pregunta con las columnas que hacen falta para decidir sobre
-- esos clientes y no solo para ordenarlos. Va aparte para no alterar la
-- respuesta de arriba.
SELECT c.cliente_id,
       c.nombre,
       c.ciudad,
       c.segmento,
       count(*)                  AS pedidos,
       -- avg() ignora los nulos, así que el ticket promedio divide por
       -- los pedidos con importe conocido. El denominador va como columna
       -- aparte porque si no, gasto_total sobre pedidos no da el ticket.
       count(v.importe)          AS pedidos_con_importe,
       sum(v.cantidad)           AS unidades,
       sum(v.importe)            AS gasto_total,
       round(avg(v.importe), 2)  AS ticket_promedio,
       -- La ventana suma sobre todos los clientes y no solo sobre los
       -- cinco que sobreviven al LIMIT, porque se evalúa antes del
       -- recorte. Da el peso real de cada uno sobre el total.
       round(100.0 * sum(v.importe) / SUM(sum(v.importe)) OVER (), 2)
                                 AS pct_del_total,
       -- El frame va explícito. El de por defecto es RANGE, que agrupa a
       -- los clientes empatados en una sola fila de acumulado; con ROWS
       -- el acumulado avanza fila por fila, que es lo que se quiere leer.
       round(100.0 * SUM(sum(v.importe)) OVER (ORDER BY sum(v.importe) DESC
                                               ROWS BETWEEN UNBOUNDED PRECEDING
                                                        AND CURRENT ROW)
             / SUM(sum(v.importe)) OVER (), 2) AS pct_acumulado
FROM ventas_limpias v
JOIN clientes c ON c.cliente_id = v.cliente_id
GROUP BY c.cliente_id, c.nombre, c.ciudad, c.segmento
ORDER BY gasto_total DESC NULLS LAST, c.cliente_id
LIMIT 5;


-- ---------------------------------------------------------------------
-- PREGUNTA 2. Cómo evoluciona la facturación mes a mes
-- ---------------------------------------------------------------------
-- El agrupamiento va con DATE_TRUNC. Si se extrajera solo el número de
-- mes, enero de 2024 caería en la misma fila que enero de 2025 y la
-- tendencia desaparecería.
--
-- La ventana calcula la variación contra el mes anterior en la misma
-- pasada, de modo que cada mes conserva su fila y no hay que duplicar la
-- tabla con una autounión.
SELECT TO_CHAR(DATE_TRUNC('month', fecha_pedido), 'YYYY-MM') AS mes,
       count(*)        AS pedidos,
       -- La facturación del mes sale de los pedidos con importe conocido,
       -- que son menos que los pedidos del mes. Sin esta columna las dos
       -- de al lado parecen compartir base y no la comparten.
       count(importe)  AS pedidos_con_importe,
       sum(importe)    AS facturacion,
       sum(importe) - LAG(sum(importe))
            OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)) AS variacion_absoluta,
       -- El porcentaje es lo que permite juzgar si un mes se salió de lo
       -- normal; en valor absoluto no hay con qué comparar el salto.
       round(100.0 * (sum(importe) - LAG(sum(importe))
                 OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)))
             / LAG(sum(importe))
                 OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)), 1) AS variacion_pct
FROM ventas_limpias
WHERE fecha_pedido IS NOT NULL   -- los pedidos sin fecha se reportan aparte
GROUP BY DATE_TRUNC('month', fecha_pedido)
ORDER BY DATE_TRUNC('month', fecha_pedido);

-- Los pedidos sin fecha no se descartan en silencio: se reportan como su
-- propio período para que se vea cuánta facturación quedó fuera de la
-- serie temporal.
SELECT periodo,
       count(*)     AS pedidos,
       sum(importe) AS facturacion
FROM ventas_limpias
WHERE periodo = 'Sin fecha'
GROUP BY periodo;

-- Cuánto se mueve la serie mes a mes. Sin esta medida no hay forma de
-- distinguir una señal de una oscilación normal, y es lo que justifica
-- sacar la conclusión del agregado anual y no de un mes suelto.
WITH mensual AS (
    SELECT DATE_TRUNC('month', fecha_pedido) AS mes, sum(importe) AS f
    FROM ventas_limpias WHERE fecha_pedido IS NOT NULL GROUP BY 1
),
variaciones AS (
    SELECT round(100.0 * (f - LAG(f) OVER (ORDER BY mes)) / LAG(f) OVER (ORDER BY mes), 1) AS var
    FROM mensual
)
SELECT round(avg(abs(var)), 1)       AS variacion_media_abs,
       round(stddev(abs(var)), 1)    AS desvio_de_esa_media,
       min(var)                      AS peor_mes,
       max(var)                      AS mejor_mes
FROM variaciones WHERE var IS NOT NULL;

-- La comparación interanual va aparte porque es la que resiste el ruido
-- mensual: cada término agrega más de dos mil pedidos.
SELECT EXTRACT(YEAR FROM fecha_pedido)::int AS anio,
       count(*)                       AS pedidos,
       count(DISTINCT fecha_pedido)   AS dias_con_pedidos,
       sum(importe)                   AS facturacion,
       round(100.0 * (sum(importe)
             - LAG(sum(importe)) OVER (ORDER BY EXTRACT(YEAR FROM fecha_pedido)))
             / LAG(sum(importe)) OVER (ORDER BY EXTRACT(YEAR FROM fecha_pedido)),
             1) AS variacion_pct,
       -- Los dos años no tienen la misma cantidad de días con actividad,
       -- así que parte de la caída es calendario y no negocio. Dividir
       -- por los días separa una cosa de la otra.
       round(sum(importe) / count(DISTINCT fecha_pedido), 2) AS facturacion_por_dia,
       round(100.0 * (sum(importe) / count(DISTINCT fecha_pedido)
             - LAG(sum(importe) / count(DISTINCT fecha_pedido))
                   OVER (ORDER BY EXTRACT(YEAR FROM fecha_pedido)))
             / LAG(sum(importe) / count(DISTINCT fecha_pedido))
                   OVER (ORDER BY EXTRACT(YEAR FROM fecha_pedido)),
             1) AS variacion_pct_por_dia
FROM ventas_limpias
WHERE fecha_pedido IS NOT NULL
GROUP BY EXTRACT(YEAR FROM fecha_pedido)
ORDER BY anio;


-- ---------------------------------------------------------------------
-- PREGUNTA 3. Cuáles son los tres productos menos vendidos
-- ---------------------------------------------------------------------
-- Va LEFT JOIN desde productos y no INNER JOIN, y la diferencia decide la
-- respuesta: un INNER JOIN solo devuelve productos que aparecen en algún
-- pedido, con lo cual esconde a los que nunca se vendieron, que son
-- justo los que la pregunta busca.
--
-- Se cuenta p.pedido_id y no *, porque count(*) contaría la fila que el
-- LEFT JOIN rellena con nulos y devolvería uno donde corresponde cero.
--
-- El desempate por producto_id mantiene el resultado reproducible, pero
-- conviene decir qué esconde: hay más de tres artículos empatados en
-- cero, así que quedarse con los tres primeros es un corte arbitrario
-- entre iguales. La consulta siguiente lista el empate completo, que es
-- la respuesta que sirve para decidir.
SELECT pr.producto_id,
       pr.nombre,
       pr.categoria,
       pr.activo,
       count(p.pedido_id)                  AS pedidos,
       COALESCE(sum(p.cantidad), 0)        AS unidades_vendidas
FROM productos pr
LEFT JOIN pedidos p ON p.producto_id = pr.producto_id
GROUP BY pr.producto_id, pr.nombre, pr.categoria, pr.activo
ORDER BY unidades_vendidas ASC, pr.producto_id ASC
LIMIT 3;

-- El empate completo, porque decidir cuál dar de baja primero no depende
-- de las unidades vendidas, que son cero en los seis, sino del capital
-- que cada uno tiene parado.
SELECT pr.producto_id,
       pr.nombre,
       pr.categoria,
       pr.activo,
       pr.stock,
       round(pr.costo * pr.stock, 2) AS capital_inmovilizado
FROM productos pr
WHERE NOT EXISTS (SELECT 1 FROM pedidos p
                  WHERE p.producto_id = pr.producto_id)
ORDER BY capital_inmovilizado DESC;

-- Y el total, que es lo que convierte el dato en una decisión de negocio
-- en lugar de una curiosidad del catálogo.
SELECT count(*)                       AS productos_sin_ninguna_venta,
       sum(stock)                     AS unidades_en_deposito,
       sum(costo * stock)             AS capital_inmovilizado,
       -- Contra la facturación del período, para dimensionar el monto.
       -- Las dos cifras no están en la misma base: el capital va a costo y
       -- la facturación a precio de venta, así que el porcentaje sirve
       -- como orden de magnitud y no como una proporción contable.
       round(100.0 * sum(costo * stock)
             / (SELECT sum(importe) FROM ventas_limpias), 1) AS pct_costo_sobre_venta,
       count(*) FILTER (WHERE activo) AS de_esos_siguen_activos
FROM productos pr
WHERE NOT EXISTS (SELECT 1 FROM pedidos p
                  WHERE p.producto_id = pr.producto_id);


-- ---------------------------------------------------------------------
-- PREGUNTA 4. Ranking de pedidos por categoría
-- ---------------------------------------------------------------------
-- Tal como la pide la consigna: los pedidos ordenados por importe dentro
-- de su categoría, con RANK(). PARTITION BY reinicia el ranking en cada
-- una, de modo que cada pedido compite contra los de su propio rubro y no
-- contra los de categorías con otro nivel de precios.
--
-- Se usa RANK y no ROW_NUMBER: dos pedidos del mismo importe tienen que
-- compartir el puesto, mientras que ROW_NUMBER los separaría de forma
-- arbitraria, dando una precisión que el dato no tiene.
--
-- El recorte va en una subconsulta porque una función de ventana no se
-- puede usar en el WHERE de la consulta que la calcula: solo se admite en
-- el SELECT y en el ORDER BY.
--
-- Se rankean únicamente los pedidos con precio original. Los que llevan
-- precio completado toman el de lista sin descuento, así que todos los de
-- un mismo producto dan exactamente el mismo importe y empatarían en
-- bloque, desplazando a pedidos reales del podio con un valor que no se
-- cobró. Un ranking mezcla importes medidos con importes estimados solo
-- si no distingue entre unos y otros.
SELECT categoria, puesto, pedido_id, cliente_id, cantidad, importe
FROM (
    SELECT v.categoria,
           v.pedido_id,
           v.cliente_id,
           v.cantidad,
           v.importe,
           RANK() OVER (PARTITION BY v.categoria ORDER BY v.importe DESC) AS puesto
    FROM ventas_limpias v
    WHERE v.origen_del_precio = 'Precio original'
) AS r
WHERE puesto <= 3
ORDER BY categoria, puesto;


-- ---------------------------------------------------------------------
-- PREGUNTA 4, extensión. Ranking de productos dentro de cada categoría
-- ---------------------------------------------------------------------
-- El ranking de pedidos de arriba responde lo pedido, pero mirado como
-- decisión de negocio dice poco: un pedido grande es un hecho aislado.
-- Agrupando por producto, en cambio, aparece de qué artículos depende
-- cada categoría, que es lo que sirve para decidir abastecimiento.
-- Comparar un producto de Electrónica contra uno de Librería no dice nada
-- porque los precios no son comparables. PARTITION BY reinicia el ranking
-- en cada categoría, de modo que cada artículo compite contra sus pares.
--
-- El puesto se calcula con RANK. Dos productos que facturan lo mismo
-- tienen que compartirlo, mientras que ROW_NUMBER los separaría de forma
-- arbitraria, dando una precisión que el dato no tiene.
WITH facturacion_por_producto AS (
    SELECT v.categoria,
           v.producto_id,
           pr.nombre,
           sum(v.importe) AS facturacion,
           sum(v.cantidad) AS unidades
    FROM ventas_limpias v
    JOIN productos pr ON pr.producto_id = v.producto_id
    GROUP BY v.categoria, v.producto_id, pr.nombre
    -- Los productos sin precio de lista quedan con facturación
    -- desconocida, y ordenar por un valor desconocido no significa nada.
    -- Además, un orden descendente pone los nulos primero, así que sin
    -- este filtro encabezarían cada categoría con el importe en blanco.
    -- Aparecen igual en la pregunta 3, que mide unidades.
    HAVING sum(v.importe) IS NOT NULL
),
ranking AS (
    -- La segunda CTE existe por una restricción del lenguaje: una función
    -- de ventana no puede usarse en el WHERE de la consulta que la
    -- calcula, porque las ventanas se evalúan después del filtrado.
    SELECT categoria,
           nombre,
           unidades,
           facturacion,
           RANK() OVER (PARTITION BY categoria ORDER BY facturacion DESC) AS puesto,
           round(100.0 * facturacion
                 / sum(facturacion) OVER (PARTITION BY categoria), 1) AS pct_de_su_categoria
    FROM facturacion_por_producto
)
SELECT categoria, puesto, nombre, unidades, facturacion, pct_de_su_categoria
FROM ranking
WHERE puesto <= 3
ORDER BY categoria, puesto;

-- Cuántos productos entran realmente al ranking de arriba y cuántas
-- unidades quedaron fuera del denominador en cada categoría. El dato
-- hace falta para leer bien los porcentajes: donde se excluyeron más
-- unidades, la participación del primer puesto sale inflada.
--
-- Para entrar al ranking un producto necesita las dos cosas, ventas y
-- precio de lista, así que se cuenta sobre la misma base que arma el
-- ranking y no sobre el catálogo entero.
SELECT pr.categoria,
       count(DISTINCT p.producto_id) FILTER (WHERE pr.precio_lista IS NOT NULL)
                                                        AS productos_en_el_ranking,
       count(DISTINCT pr.producto_id)                   AS productos_del_catalogo,
       COALESCE(sum(p.cantidad) FILTER (WHERE pr.precio_lista IS NULL), 0)
                                                        AS unidades_fuera_del_calculo
FROM productos pr
LEFT JOIN pedidos p ON p.producto_id = pr.producto_id
GROUP BY pr.categoria
ORDER BY unidades_fuera_del_calculo DESC;


-- ---------------------------------------------------------------------
-- PREGUNTA 5. Cómo se reparte la cartera de clientes
-- ---------------------------------------------------------------------
-- Un promedio general esconde que no todos los clientes valen lo mismo.
-- La clasificación permite tratarlos distinto: a quién retener, a quién
-- hacer crecer y a quién dejar de perseguir.
--
-- Va LEFT JOIN desde clientes por el mismo motivo que la pregunta 3: los
-- que nunca compraron son un hallazgo, no un dato faltante.
WITH gasto_por_cliente AS (
    SELECT c.cliente_id,
           c.segmento,
           count(v.pedido_id)           AS pedidos,
           COALESCE(sum(v.importe), 0)  AS gasto
    FROM clientes c
    LEFT JOIN ventas_limpias v ON v.cliente_id = c.cliente_id
    GROUP BY c.cliente_id, c.segmento
),
-- Los cortes salen de los cuartiles de la propia distribución. Un umbral
-- escrito a mano envejece mal: si cambia el volumen del negocio, la
-- clasificación deja de significar lo mismo.
clasificados AS (
    SELECT cliente_id,
           segmento,
           pedidos,
           gasto,
           CASE WHEN pedidos = 0 THEN 0
                ELSE NTILE(4) OVER (PARTITION BY (pedidos = 0)
                                    ORDER BY gasto DESC, cliente_id)
           END AS cuartil
    FROM gasto_por_cliente
)
SELECT CASE cuartil WHEN 0 THEN 'Sin actividad'
                    WHEN 1 THEN 'Cuartil 1, los que más gastan'
                    WHEN 2 THEN 'Cuartil 2'
                    WHEN 3 THEN 'Cuartil 3'
                    ELSE        'Cuartil 4, los que menos gastan'
       END AS clasificacion,
       count(*)                 AS clientes,
       sum(pedidos)             AS pedidos,
       sum(gasto)               AS facturacion,
       round(100.0 * sum(gasto) / SUM(sum(gasto)) OVER (), 1) AS pct_facturacion
FROM clasificados
GROUP BY cuartil
ORDER BY cuartil;


-- ---------------------------------------------------------------------
-- PREGUNTA 6. Por dónde entra la facturación
-- ---------------------------------------------------------------------
-- Las preguntas anteriores miran cuánto vale cada cliente. Esta mira otra
-- cosa: por qué canal llega la plata y de qué antigüedad de cliente. Sirve
-- para repartir presupuesto comercial, porque un canal que trae mucho
-- volumen de clientes nuevos y otro que sostiene a los históricos piden
-- inversiones distintas.
--
-- El cruce se arma con FILTER sobre la misma pasada en lugar de tres
-- consultas separadas, y la última columna usa una ventana para dar el
-- peso de cada canal sobre el total sin necesidad de una subconsulta.
SELECT v.canal,
       count(*)                                              AS pedidos,
       -- Mismo criterio que en las preguntas 1 y 2: el ticket promedio se
       -- calcula sobre los pedidos con importe, no sobre todos.
       count(v.importe)                                      AS pedidos_con_importe,
       sum(v.cantidad)                                       AS unidades,
       round(avg(v.importe), 2)                              AS ticket_promedio,
       sum(v.importe)                                        AS facturacion,
       round(100.0 * sum(v.importe) / SUM(sum(v.importe)) OVER (), 1)
                                                             AS pct_del_total,
       sum(v.importe) FILTER (WHERE c.segmento = 'Histórico')  AS de_historicos,
       sum(v.importe) FILTER (WHERE c.segmento = 'Recurrente') AS de_recurrentes,
       sum(v.importe) FILTER (WHERE c.segmento = 'Nuevo')      AS de_nuevos,
       round(100.0 * sum(v.importe) FILTER (WHERE c.segmento = 'Nuevo')
             / sum(v.importe), 1)                            AS pct_de_nuevos
FROM ventas_limpias v
JOIN clientes c ON c.cliente_id = v.cliente_id
GROUP BY v.canal
ORDER BY facturacion DESC;


-- #####################################################################
-- CIERRE
-- #####################################################################
-- Cifras de cierre, para que quien reciba el informe pueda contrastar de
-- un vistazo los totales contra los que se citan en el README.
SELECT count(*)                    AS pedidos_analizados,
       count(importe)              AS con_importe_conocido,
       sum(importe)                AS facturacion_total,
       count(DISTINCT cliente_id)  AS clientes_con_compras,
       count(DISTINCT producto_id) AS productos_vendidos
FROM ventas_limpias;
