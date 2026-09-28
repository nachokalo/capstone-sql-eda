-- =====================================================================
-- Proyecto Capstone: Análisis Exploratorio de Datos en PostgreSQL
-- analisis.sql - Limpieza y consultas de análisis
-- Ignacio Kalogiannidis - PostgreSQL 16
-- =====================================================================
--
-- Ejecución, en este orden:
--   psql -v ON_ERROR_STOP=1 -d capstone_project -f estructura.sql
--   psql -v ON_ERROR_STOP=1 -d capstone_project -f analisis.sql
--
-- Dos partes y un cierre. La parte 1 perfila y limpia. La parte 2
-- resuelve los cuatro puntos de análisis del enunciado, que pedía al
-- menos tres, y agrega dos preguntas más: seis en total, con lo que se
-- pasan las cinco preguntas de negocio que pide el documento del módulo.
--
-- Cada punto arranca con la consulta tal como la pide el enunciado y,
-- cuando hace falta, sigue con una extensión rotulada que agrega
-- columnas para poder decidir. Ese orden es deliberado: la respuesta
-- pedida se entrega sola, sin columnas de más, y lo que agrego va al
-- lado sin tocarla.
--
-- No modifica ninguna tabla, solo lee y crea una vista.
--
-- Las funciones de ventana se escriben en mayúscula y las de agregación
-- en minúscula, para que se distingan de un vistazo cuando una envuelve
-- a la otra.


-- #####################################################################
-- PARTE 1. PERFILADO Y LIMPIEZA
-- #####################################################################
-- Un NULL no es un cero. El cero afirma que la venta fue de cero pesos;
-- el NULL admite que no sabemos cuánto fue. Confundirlos hunde promedios
-- y totales, así que cada hueco se trata por separado y con un criterio
-- declarado.


-- ---------------------------------------------------------------------
-- 1.1. Verificación de los tipos de dato
-- ---------------------------------------------------------------------
-- Se revisa antes de analizar: un tipo mal elegido obliga a convertir en
-- cada consulta y abre la puerta a errores de redondeo y de orden. El
-- control no se queda en listar los tipos declarados, que son los que el
-- script anterior escribió: marca ALERTA si alguno no es el que el
-- análisis necesita.
SELECT 1 AS orden,
       'dinero en NUMERIC y no en punto flotante' AS control,
       count(*) AS columnas_mal,
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ALERTA' END AS resultado
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('clientes','productos','pedidos')
  AND column_name IN ('precio_lista','costo','precio_unitario')
  AND data_type <> 'numeric'
UNION ALL
SELECT 2,
       'fechas en DATE y no en texto',
       count(*),
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ALERTA' END
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('clientes','productos','pedidos')
  AND column_name IN ('fecha_pedido','fecha_alta')
  AND data_type <> 'date'
UNION ALL
SELECT 3,
       'texto en TEXT y no en VARCHAR con límite',
       count(*),
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ALERTA' END
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('clientes','productos','pedidos')
  AND character_maximum_length IS NOT NULL
-- El orden de un UNION ALL no está garantizado, así que se declara.
ORDER BY orden;


-- Lo anterior informa; esto exige. Va acá arriba, antes de cualquier
-- suma, porque un tipo equivocado o un cruce que multiplica filas
-- ensucian todos los totales que vienen después: si el script llegara a
-- imprimirlos y recién entonces cortara, el daño ya estaría hecho.
DO $$
DECLARE
    base int := (SELECT count(*) FROM pedidos);
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name IN ('clientes','productos','pedidos')
                 AND ((column_name IN ('precio_lista','costo','precio_unitario')
                       AND data_type <> 'numeric')
                   OR (column_name IN ('fecha_pedido','fecha_alta')
                       AND data_type <> 'date')
                   OR character_maximum_length IS NOT NULL)) THEN
        RAISE EXCEPTION 'Hay columnas con un tipo distinto del que el análisis supone';
    END IF;

    -- Las dos claves por las que cruza todo el análisis, controladas
    -- contra las tablas porque la vista todavía no existe. Alcanza con
    -- dos porque el tercer cruce de la sección 1.4 vuelve a usar
    -- productos.producto_id.
    IF (SELECT count(*) FROM pedidos p
        JOIN productos pr ON pr.producto_id = p.producto_id) <> base THEN
        RAISE EXCEPTION 'El cruce de pedidos con productos multiplicó filas';
    END IF;
    IF (SELECT count(*) FROM pedidos p
        JOIN clientes c ON c.cliente_id = p.cliente_id) <> base THEN
        RAISE EXCEPTION 'El cruce de pedidos con clientes multiplicó filas';
    END IF;

    RAISE NOTICE 'Tipos de dato y cardinalidad de los cruces: verificados.';
END $$;


-- ---------------------------------------------------------------------
-- 1.2. Cuánto hueco hay y dónde
-- ---------------------------------------------------------------------
-- Se mide antes de decidir nada: no es lo mismo que el problema afecte
-- al uno por ciento de las filas que al treinta. El denominador va con
-- NULLIF para que la consulta devuelva NULL y no un error si algún día
-- corre contra una tabla vacía.
SELECT count(*) AS pedidos_totales,
       count(*) FILTER (WHERE precio_unitario IS NULL) AS sin_precio_unitario,
       round(100.0 * count(*) FILTER (WHERE precio_unitario IS NULL)
             / NULLIF(count(*), 0), 1) AS pct_sin_precio,
       count(*) FILTER (WHERE fecha_pedido IS NULL) AS sin_fecha,
       round(100.0 * count(*) FILTER (WHERE fecha_pedido IS NULL)
             / NULLIF(count(*), 0), 1) AS pct_sin_fecha
FROM pedidos;

-- Los pedidos sin ninguna fuente de precio van a quedar fuera de los
-- totales de facturación, así que hay que saber dónde caen. Si se
-- concentraran en una categoría, la comparación entre categorías
-- quedaría sesgada sin que se note en el promedio general.
SELECT pr.categoria,
       count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NULL) AS sin_ninguna_fuente,
       count(*)                                        AS pedidos_de_la_categoria,
       round(100.0 * count(*) FILTER (WHERE p.precio_unitario IS NULL
                                        AND pr.precio_lista IS NULL)
             / NULLIF(count(*), 0), 1)                 AS pct
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id
GROUP BY pr.categoria
ORDER BY pr.categoria;

-- El mismo hueco mirado por tamaño de pedido. Estar repartido entre
-- categorías no alcanza: si se concentrara en los pedidos de una sola
-- unidad, el ticket promedio que informa el resto del análisis saldría
-- corrido hacia arriba.
SELECT p.cantidad,
       count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NULL) AS sin_ninguna_fuente,
       count(*)                                        AS pedidos_de_esa_cantidad,
       round(100.0 * count(*) FILTER (WHERE p.precio_unitario IS NULL
                                        AND pr.precio_lista IS NULL)
             / NULLIF(count(*), 0), 1)                 AS pct
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id
GROUP BY p.cantidad
ORDER BY p.cantidad;

-- El hueco de precio tiene dos gravedades: una se puede reparar con el
-- precio de lista del producto y la otra no tiene de dónde salir.
SELECT count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NOT NULL) AS recuperables_con_lista,
       count(*) FILTER (WHERE p.precio_unitario IS NULL
                          AND pr.precio_lista IS NULL)     AS sin_ninguna_fuente,
       -- El peso de lo irrecuperable marca cuánto le falta al número
       -- final, y va al pie de cualquier informe de facturación.
       round(100.0 * count(*) FILTER (WHERE p.precio_unitario IS NULL
                                        AND pr.precio_lista IS NULL)
             / NULLIF((SELECT count(*) FROM pedidos), 0), 1) AS pct_irrecuperable
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id
WHERE p.precio_unitario IS NULL;


-- ---------------------------------------------------------------------
-- 1.3. La vista limpia, base de todo el análisis
-- ---------------------------------------------------------------------
-- La limpieza se resuelve en un solo lugar para que las consultas
-- partan del mismo criterio. Si cada una limpiara por su cuenta,
-- alcanzaría con que a una se le escapara el COALESCE para que los
-- totales del informe dejaran de cerrar entre sí.
--
-- Precio: cuando el pedido no trae importe se usa el precio de lista del
-- producto. Cuando tampoco hay precio de lista, el importe queda en NULL:
-- la venta se cuenta como unidad movida, pero taparla con un cero sería
-- afirmar que se regaló.
--
-- La imputación tiene un sesgo conocido y conviene dejarlo escrito acá,
-- que es donde se produce: el precio de lista no lleva el descuento que
-- sí tienen los pedidos con precio propio, así que el importe completado
-- queda algunos puntos por encima de lo que se habría cobrado. La
-- columna origen_del_precio existe para poder medirlo y para poder
-- excluir esas filas cuando el análisis lo necesita.
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
ORDER BY sum(importe) DESC NULLS LAST, origen_del_precio;

-- El número que justifica haber hecho la limpieza: lo que se habría
-- perdido dejando los nulos afuera de la suma en lugar de completarlos.
SELECT sum(cantidad * precio_unitario)                       AS sin_limpiar,
       (SELECT sum(importe) FROM ventas_limpias)             AS con_limpieza,
       (SELECT sum(importe) FROM ventas_limpias)
           - sum(cantidad * precio_unitario)                 AS diferencia
FROM pedidos;

-- El dato que hace falta para juzgar si la imputación es razonable:
-- cuánto se aparta el precio cobrado del de lista. Si el descuento
-- observado fuera de otro orden de magnitud, completar con el precio de
-- lista dejaría de ser una estimación y pasaría a ser un número
-- inventado.
SELECT count(*)                                              AS pedidos_medidos,
       round(min(100.0 * (1 - p.precio_unitario / NULLIF(pr.precio_lista, 0))), 1) AS descuento_min_pct,
       round(max(100.0 * (1 - p.precio_unitario / NULLIF(pr.precio_lista, 0))), 1) AS descuento_max_pct,
       round(avg(100.0 * (1 - p.precio_unitario / NULLIF(pr.precio_lista, 0))), 2) AS descuento_medio_pct
FROM pedidos p
JOIN productos pr ON pr.producto_id = p.producto_id
WHERE p.precio_unitario IS NOT NULL
  AND pr.precio_lista IS NOT NULL;

-- Por qué el costo es mejor referencia que el promedio del rubro, con el
-- caso más claro a la vista: el margen que le quedaría al artículo más
-- barato si se lo valuara al precio unitario medio de su categoría,
-- contra la banda de márgenes que muestra el catálogo entero.
WITH banda AS (
    SELECT min(costo / precio_lista) AS margen_min,
           max(costo / precio_lista) AS margen_max
    FROM productos WHERE precio_lista IS NOT NULL
),
medio_categoria AS (
    SELECT pr.categoria, avg(p.precio_unitario) AS precio_medio
    FROM pedidos p
    JOIN productos pr ON pr.producto_id = p.producto_id
    WHERE p.precio_unitario IS NOT NULL
    GROUP BY pr.categoria
)
SELECT pr.producto_id,
       pr.nombre,
       pr.categoria,
       pr.costo,
       round(m.precio_medio, 2)                                AS precio_medio_del_rubro,
       round((pr.costo / m.precio_medio)::numeric, 4)          AS margen_que_le_quedaria,
       round(b.margen_min::numeric, 4)                         AS margen_minimo_del_catalogo,
       round(b.margen_max::numeric, 4)                         AS margen_maximo_del_catalogo
FROM productos pr
JOIN medio_categoria m ON m.categoria = pr.categoria
CROSS JOIN banda b
WHERE pr.precio_lista IS NULL
ORDER BY pr.costo, pr.producto_id
LIMIT 1;

-- Cuánto de esa diferencia es sesgo de la imputación. Se compara el
-- precio de lista contra el precio que efectivamente se cobró en los
-- pedidos del mismo producto que sí lo traen. Es la medida de cuánto
-- sobra en el número recuperado, y sin ella el informe presentaría como
-- exacto algo que es una estimación con dirección conocida.
WITH cobrado_por_producto AS (
    SELECT producto_id, avg(precio_unitario) AS precio_medio_cobrado
    FROM pedidos
    WHERE precio_unitario IS NOT NULL
    GROUP BY producto_id
)
SELECT count(*)                                                 AS pedidos_imputados,
       round(sum(v.cantidad * pr.precio_lista), 2)              AS imputado_a_precio_de_lista,
       round(sum(v.cantidad * c.precio_medio_cobrado), 2)       AS estimado_al_precio_cobrado,
       round(sum(v.cantidad * (pr.precio_lista - c.precio_medio_cobrado)), 2)
                                                                AS sobreestimacion,
       round(100.0 * sum(v.cantidad * (pr.precio_lista - c.precio_medio_cobrado))
             / NULLIF(sum(v.cantidad * pr.precio_lista), 0), 2)  AS sobreestimacion_pct
FROM ventas_limpias v
JOIN productos pr            ON pr.producto_id = v.producto_id
-- El cruce es interno: si algún artículo imputado no tuviera ninguna
-- venta con precio propio, sus pedidos desaparecerían de la estimación
-- en silencio. El conteo de la primera columna es lo que permite
-- comprobar que no pasó, porque tiene que dar los mismos 416 que informa
-- el perfilado de más arriba.
JOIN cobrado_por_producto c  ON c.producto_id  = v.producto_id
WHERE v.origen_del_precio = 'Completado con precio de lista';

-- La mejora que se desprende de lo anterior, ejecutada y no solamente
-- nombrada: imputar el precio de lista afectado por el descuento medio
-- observado en lugar del precio de lista pelado. El descuento se calcula
-- acá mismo, no se escribe a mano, para que la corrección siga siendo
-- válida si cambian los datos.
--
-- El descuento se puede promediar de dos formas y no dan lo mismo, así
-- que van las dos en lugar de elegir una y afirmar que la otra no
-- cambia nada: el promedio simple, que trata igual a todos los pedidos,
-- y el ponderado por importe, que le da más peso a los pedidos grandes.
-- La diferencia entre las dos correcciones es la última columna.
WITH descuento AS (
    SELECT avg(1 - p.precio_unitario / pr.precio_lista) AS simple,
           sum(p.cantidad * pr.precio_lista - p.cantidad * p.precio_unitario)
               / sum(p.cantidad * pr.precio_lista) AS ponderado
    FROM pedidos p
    JOIN productos pr ON pr.producto_id = p.producto_id
    WHERE p.precio_unitario IS NOT NULL
      AND pr.precio_lista IS NOT NULL
)
SELECT round((SELECT sum(importe) FROM ventas_limpias), 2) AS total_como_se_informa,
       round(sum(v.cantidad * pr.precio_lista * d.simple), 2)    AS correccion_simple,
       round(sum(v.cantidad * pr.precio_lista * d.ponderado), 2) AS correccion_ponderada,
       round((SELECT sum(importe) FROM ventas_limpias)
             - sum(v.cantidad * pr.precio_lista * d.simple), 2)
                                                           AS total_con_descuento_aplicado,
       round(sum(v.cantidad * pr.precio_lista * (d.simple - d.ponderado)), 2)
                                                           AS diferencia_entre_las_dos
FROM ventas_limpias v
JOIN productos pr ON pr.producto_id = v.producto_id
CROSS JOIN descuento d
WHERE v.origen_del_precio = 'Completado con precio de lista';

-- Y del otro lado, cuánto le falta al total por los pedidos que no
-- tienen ninguna fuente de precio. Esos no entran en ninguna suma, así
-- que la facturación informada es un piso; sin esta estimación no hay
-- forma de saber si el piso está uno o diez por ciento abajo.
--
-- El precio exacto de esos artículos no se puede saber, pero sí se puede
-- acotar, y el camino es el costo. Sobre los 54 artículos que tienen las
-- dos columnas, la relación costo sobre precio de lista se mueve dentro
-- de una banda conocida; dividiendo el costo del artículo sin precio por
-- los extremos de esa banda queda encerrado su precio, y dividiéndolo
-- por la mediana queda la estimación puntual. Es mejor referencia que el
-- precio medio de la categoría, porque usa el artículo mismo: valuar un
-- artículo de 124,80 de costo al promedio de su rubro le atribuiría un
-- margen que no existe en ninguna parte del catálogo.
-- Primero, artículo por artículo, para que se vea de dónde sale la
-- estimación y qué tan ancha es la banda en cada caso.
WITH margen AS (
    SELECT min(costo / precio_lista) AS mas_bajo,
           max(costo / precio_lista) AS mas_alto,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY costo / precio_lista) AS mediana
    FROM productos
    WHERE precio_lista IS NOT NULL
)
SELECT pr.producto_id,
       pr.categoria,
       pr.costo,
       round((pr.costo / m.mas_alto)::numeric, 2) AS precio_estimado_minimo,
       round((pr.costo / m.mediana)::numeric, 2)  AS precio_estimado_central,
       round((pr.costo / m.mas_bajo)::numeric, 2) AS precio_estimado_maximo,
       COALESCE((SELECT sum(v.cantidad) FROM ventas_limpias v
                 WHERE v.producto_id = pr.producto_id), 0) AS unidades_vendidas
FROM productos pr
CROSS JOIN margen m
WHERE pr.precio_lista IS NULL
ORDER BY pr.producto_id;

-- Y el total de los 318 pedidos que dependen de esos artículos.
WITH margen AS (
    SELECT min(costo / precio_lista) AS mas_bajo,
           max(costo / precio_lista) AS mas_alto,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY costo / precio_lista) AS mediana
    FROM productos
    WHERE precio_lista IS NOT NULL
)
SELECT count(*)                                            AS pedidos_sin_fuente,
       sum(v.cantidad)                                     AS unidades,
       round(sum(v.cantidad * pr.costo / m.mas_alto)::numeric, 2)  AS estimacion_minima,
       round(sum(v.cantidad * pr.costo / m.mediana)::numeric, 2)   AS estimacion_central,
       round(sum(v.cantidad * pr.costo / m.mas_bajo)::numeric, 2)  AS estimacion_maxima,
       round((100.0 * sum(v.cantidad * pr.costo / m.mediana)
             / NULLIF((SELECT sum(importe) FROM ventas_limpias), 0))::numeric, 2)
                                                           AS pct_central_sobre_lo_informado
FROM ventas_limpias v
JOIN productos pr ON pr.producto_id = v.producto_id
CROSS JOIN margen m
WHERE v.origen_del_precio = 'Sin precio disponible';


-- ---------------------------------------------------------------------
-- 1.4. Control de integridad del JOIN
-- ---------------------------------------------------------------------
-- Es el error más silencioso de los que puede tener este análisis: si la
-- clave del lado derecho no fuera única, cada fila se duplicaría y todos
-- los totales quedarían inflados sin que nada falle. El conteo antes y
-- después tiene que dar igual.
--
-- Se controlan los tres cruces que usa el análisis, que van por dos
-- claves: clientes.cliente_id, y productos.producto_id, que entra dos
-- veces porque lo pide la vista y después el ranking. Hoy las dos son
-- claves primarias declaradas y el control no puede dar ALERTA; queda
-- como red para el día en que alguno de los cruces pase a usar una
-- columna sin unicidad garantizada, que es cuando el error aparece sin
-- que nada falle.
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
FROM controles
ORDER BY cruce;

-- La tabla de arriba informa; el bloque que las exige está más arriba,
-- antes de la vista, porque de nada sirve enterarse de que un cruce
-- multiplica filas después de haber impreso los totales calculados sobre
-- esas filas de más.


-- #####################################################################
-- PARTE 2. ANÁLISIS
-- #####################################################################
-- Los cuatro puntos que enumera el enunciado van primero, con su
-- redacción literal en el título. Después van dos preguntas adicionales,
-- rotuladas como tales, que no reemplazan ni modifican nada de lo
-- anterior.


-- ---------------------------------------------------------------------
-- PUNTO 1 DEL ENUNCIADO. Top 5 clientes por gasto total (GROUP BY + SUM)
-- ---------------------------------------------------------------------
-- Tal como la pide la consigna: gasto total por cliente con GROUP BY y
-- SUM, y los cinco primeros. El gasto es el medible, o sea el de los
-- pedidos con importe conocido; los que no lo tienen se reportan en la
-- parte 1 y no entran en ninguna suma.
SELECT c.cliente_id,
       c.nombre,
       sum(v.importe) AS gasto_total
FROM ventas_limpias v
JOIN clientes c ON c.cliente_id = v.cliente_id
GROUP BY c.cliente_id, c.nombre
ORDER BY gasto_total DESC NULLS LAST, c.cliente_id
LIMIT 5;

-- PUNTO 1, extensión A. Las columnas que hacen falta para decidir sobre
-- esos clientes, además de las que alcanzan para ordenarlos. Va aparte
-- para no alterar la respuesta de arriba.
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
       round(100.0 * sum(v.importe) / NULLIF(SUM(sum(v.importe)) OVER (), 0), 2)
                                 AS pct_del_total,
       -- El frame va explícito. Con el RANGE por defecto, dos clientes
       -- que facturaran lo mismo compartirían el valor del acumulado en
       -- lugar de avanzar de a uno. Acá no hay empates, así que las dos
       -- formas dan igual; se escribe para que el resultado no dependa
       -- de esa casualidad.
       round(100.0 * SUM(sum(v.importe)) OVER (ORDER BY sum(v.importe) DESC
                                               ROWS BETWEEN UNBOUNDED PRECEDING
                                                        AND CURRENT ROW)
             / NULLIF(SUM(sum(v.importe)) OVER (), 0), 2) AS pct_acumulado
FROM ventas_limpias v
JOIN clientes c ON c.cliente_id = v.cliente_id
GROUP BY c.cliente_id, c.nombre, c.ciudad, c.segmento
ORDER BY gasto_total DESC NULLS LAST, c.cliente_id
LIMIT 5;

-- PUNTO 1, extensión B. Qué tan firme es el corte del quinto puesto.
-- Si la distancia contra el sexto fuera menor que lo que vale un pedido
-- sin importe conocido, el orden de la frontera sería una casualidad de
-- la limpieza antes que un dato.
SELECT cliente_id, nombre, gasto_total, pedidos_sin_importe,
       gasto_total - LEAD(gasto_total) OVER (ORDER BY gasto_total DESC, cliente_id)
                                                       AS ventaja_sobre_el_siguiente
FROM (
    SELECT c.cliente_id,
           c.nombre,
           sum(v.importe)                                  AS gasto_total,
           count(*) FILTER (WHERE v.importe IS NULL)        AS pedidos_sin_importe
    FROM ventas_limpias v
    JOIN clientes c ON c.cliente_id = v.cliente_id
    GROUP BY c.cliente_id, c.nombre
    ORDER BY gasto_total DESC NULLS LAST, c.cliente_id
    LIMIT 7
) AS frontera
ORDER BY gasto_total DESC, cliente_id;


-- ---------------------------------------------------------------------
-- PUNTO 2 DEL ENUNCIADO. Ventas totales por mes (funciones de fecha)
-- ---------------------------------------------------------------------
-- Tal como la pide la consigna: el mes y la facturación de ese mes. El
-- agrupamiento va con DATE_TRUNC. Si se extrajera solo el número de mes,
-- enero de 2024 caería en la misma fila que enero de 2025 y la tendencia
-- desaparecería.
SELECT TO_CHAR(DATE_TRUNC('month', fecha_pedido), 'YYYY-MM') AS mes,
       sum(importe) AS facturacion
FROM ventas_limpias
WHERE fecha_pedido IS NOT NULL   -- los pedidos sin fecha se reportan aparte
GROUP BY DATE_TRUNC('month', fecha_pedido)
ORDER BY DATE_TRUNC('month', fecha_pedido);

-- PUNTO 2, extensión A. La misma serie con la variación contra el mes
-- anterior, sin la cual no hay forma de juzgar si un mes se salió de lo
-- normal. La ventana la calcula en la misma pasada, así cada mes
-- conserva su fila sin necesidad de duplicar la tabla con una autounión.
--
-- LAG toma el mes anterior de la serie y no el mes calendario anterior.
-- Acá los veinticuatro meses están todos, así que coinciden; si algún mes
-- quedara sin pedidos, la comparación saltaría ese hueco sin avisar.
SELECT TO_CHAR(DATE_TRUNC('month', fecha_pedido), 'YYYY-MM') AS mes,
       count(*)        AS pedidos,
       -- Los meses no tienen todos la misma cantidad de días, así que
       -- parte de la variación es calendario. La columna está para que
       -- no se lea un febrero como una caída del negocio.
       count(DISTINCT fecha_pedido) AS dias_con_pedidos,
       -- La facturación del mes sale de los pedidos con importe conocido,
       -- que son menos que los pedidos del mes. Sin esta columna las dos
       -- de al lado aparentan compartir base cuando no la comparten.
       count(importe)  AS pedidos_con_importe,
       sum(importe)    AS facturacion,
       sum(importe) - LAG(sum(importe))
            OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)) AS variacion_absoluta,
       round(100.0 * (sum(importe) - LAG(sum(importe))
                 OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)))
             / NULLIF(LAG(sum(importe))
                 OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)), 0), 1) AS variacion_pct,
       -- La misma variación dividida por los días con actividad del mes.
       -- Es el mismo criterio que se aplica a la comparación interanual, y
       -- sin él un febrero de 28 días se lee como una caída del negocio.
       round(sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0), 2) AS facturacion_por_dia,
       round(100.0 * (sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0)
             - LAG(sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0))
                   OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)))
             / NULLIF(LAG(sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0))
                   OVER (ORDER BY DATE_TRUNC('month', fecha_pedido)), 0), 1)
                                                                       AS variacion_pct_por_dia
FROM ventas_limpias
WHERE fecha_pedido IS NOT NULL
GROUP BY DATE_TRUNC('month', fecha_pedido)
ORDER BY DATE_TRUNC('month', fecha_pedido);

-- PUNTO 2, extensión B. Los pedidos sin fecha no se descartan en
-- silencio: se reportan como su propio período para que se vea cuánta
-- facturación quedó fuera de la serie temporal.
SELECT periodo,
       count(*)        AS pedidos,
       -- El denominador va declarado acá también: no todos esos pedidos
       -- tienen importe conocido, así que la facturación de la tercera
       -- columna no sale de los 157 de la segunda.
       count(importe)  AS pedidos_con_importe,
       sum(importe)    AS facturacion
FROM ventas_limpias
WHERE periodo = 'Sin fecha'
GROUP BY periodo;

-- PUNTO 2, extensión C. Cuánto se mueve la serie mes a mes. Sin esta
-- medida no hay forma de distinguir una señal de una oscilación normal,
-- y es lo que justifica sacar la conclusión del agregado anual en lugar
-- de un mes suelto.
--
-- Se mide sobre las dos series, la nominal y la normalizada por día con
-- actividad, porque son cosas distintas: buena parte de la oscilación
-- nominal es la cantidad de días del mes, y separar las dos es lo que
-- permite decir cuánto de la amplitud es negocio.
WITH mensual AS (
    SELECT DATE_TRUNC('month', fecha_pedido) AS mes,
           sum(importe) AS f,
           sum(importe) / count(DISTINCT fecha_pedido) AS f_dia
    FROM ventas_limpias WHERE fecha_pedido IS NOT NULL GROUP BY 1
),
variaciones AS (
    SELECT round(100.0 * (f - LAG(f) OVER (ORDER BY mes))
                 / NULLIF(LAG(f) OVER (ORDER BY mes), 0), 1) AS var,
           round((100.0 * (f_dia - LAG(f_dia) OVER (ORDER BY mes))
                 / NULLIF(LAG(f_dia) OVER (ORDER BY mes), 0))::numeric, 1) AS var_dia
    FROM mensual
)
SELECT round(avg(abs(var)), 1)         AS variacion_media_abs,
       round(stddev(abs(var)), 1)      AS desvio_de_esa_media,
       min(var)                        AS peor_variacion_pct,
       max(var)                        AS mejor_variacion_pct,
       round(avg(abs(var_dia)), 1)     AS variacion_media_abs_por_dia,
       round(stddev(abs(var_dia)), 1)  AS desvio_por_dia,
       min(var_dia)                    AS peor_variacion_pct_por_dia,
       max(var_dia)                    AS mejor_variacion_pct_por_dia
FROM variaciones WHERE var IS NOT NULL;

-- PUNTO 2, extensión D. La comparación interanual va aparte porque
-- resiste el ruido mensual: cada término se apoya en más de dos mil
-- doscientos pedidos. El año se agrupa con DATE_TRUNC por el mismo
-- criterio que el mes.
SELECT TO_CHAR(DATE_TRUNC('year', fecha_pedido), 'YYYY') AS anio,
       count(*)                       AS pedidos,
       count(DISTINCT fecha_pedido)   AS dias_con_pedidos,
       sum(importe)                   AS facturacion,
       round(100.0 * (sum(importe)
             - LAG(sum(importe)) OVER (ORDER BY DATE_TRUNC('year', fecha_pedido)))
             / NULLIF(LAG(sum(importe)) OVER (ORDER BY DATE_TRUNC('year', fecha_pedido)), 0),
             1) AS variacion_pct,
       -- Los dos años no tienen la misma cantidad de días con actividad,
       -- así que parte de la caída es calendario y no negocio. Dividir
       -- por los días separa una cosa de la otra.
       round(sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0), 2) AS facturacion_por_dia,
       round(100.0 * (sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0)
             - LAG(sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0))
                   OVER (ORDER BY DATE_TRUNC('year', fecha_pedido)))
             / NULLIF(LAG(sum(importe) / NULLIF(count(DISTINCT fecha_pedido), 0))
                   OVER (ORDER BY DATE_TRUNC('year', fecha_pedido)), 0),
             1) AS variacion_pct_por_dia
FROM ventas_limpias
WHERE fecha_pedido IS NOT NULL
GROUP BY DATE_TRUNC('year', fecha_pedido)
ORDER BY anio;


-- ---------------------------------------------------------------------
-- PUNTO 3 DEL ENUNCIADO. 3 productos menos vendidos
-- ---------------------------------------------------------------------
-- Tal como la pide la consigna: el producto y las unidades que vendió,
-- los tres de abajo.
--
-- Va LEFT JOIN desde productos y no INNER JOIN, y la diferencia decide la
-- respuesta: un INNER JOIN solo devuelve productos que aparecen en algún
-- pedido, con lo cual esconde a los que nunca se vendieron, que son
-- justo los que el punto 3 busca.
--
-- Las unidades van con COALESCE sobre la suma: un producto sin ventas
-- no tiene filas del lado de pedidos, así que sum() devuelve NULL, y
-- ordenar por NULL ascendente lo mandaría al final del listado, que es
-- el lugar contrario al que le corresponde.
SELECT pr.producto_id,
       pr.nombre,
       COALESCE(sum(p.cantidad), 0) AS unidades_vendidas
FROM productos pr
LEFT JOIN pedidos p ON p.producto_id = pr.producto_id
GROUP BY pr.producto_id, pr.nombre
ORDER BY unidades_vendidas ASC, pr.producto_id ASC
LIMIT 3;

-- PUNTO 3, extensión A. El desempate por producto_id de arriba mantiene
-- el resultado reproducible, pero esconde algo: hay más de tres artículos
-- en cero unidades, así que quedarse con los tres primeros corta entre
-- iguales. Acá está el empate completo, ordenado por el capital que tiene
-- parado cada uno, que es el criterio que sirve para decidir por cuál
-- empezar.
SELECT pr.producto_id,
       pr.nombre,
       pr.categoria,
       pr.activo,
       pr.stock,
       round(pr.costo * pr.stock, 2) AS capital_inmovilizado
FROM productos pr
WHERE NOT EXISTS (SELECT 1 FROM pedidos p
                  WHERE p.producto_id = pr.producto_id)
ORDER BY capital_inmovilizado DESC, pr.producto_id;

-- PUNTO 3, extensión B. El total, sin el cual el dato se queda en una
-- curiosidad del catálogo en vez de convertirse en una decisión.
SELECT count(*)                       AS productos_sin_ninguna_venta,
       sum(stock)                     AS unidades_en_deposito,
       sum(costo * stock)             AS capital_inmovilizado,
       -- Contra la facturación del período, para dimensionar el monto.
       -- Las dos cifras no están en la misma base: el capital va a costo y
       -- la facturación a precio de venta, así que el porcentaje sirve
       -- como orden de magnitud y no como una proporción contable.
       round(100.0 * sum(costo * stock)
             / NULLIF((SELECT sum(importe) FROM ventas_limpias), 0), 1)
                                      AS pct_costo_sobre_venta,
       count(*) FILTER (WHERE activo) AS de_esos_siguen_activos
FROM productos pr
WHERE NOT EXISTS (SELECT 1 FROM pedidos p
                  WHERE p.producto_id = pr.producto_id);


-- ---------------------------------------------------------------------
-- PUNTO 4 DEL ENUNCIADO. Ranking de pedidos por categoría con RANK()
-- ---------------------------------------------------------------------
-- Tal como la pide la consigna: los pedidos ordenados por importe dentro
-- de su categoría. PARTITION BY reinicia el ranking en cada una, de modo
-- que cada pedido compite contra los de su propio rubro y no contra los
-- de categorías con otro nivel de precios.
--
-- Se usa RANK y no ROW_NUMBER: dos pedidos del mismo importe tienen que
-- compartir el puesto, mientras que ROW_NUMBER los separaría de forma
-- arbitraria, dando una precisión que el dato no tiene.
--
-- El recorte va en una subconsulta porque una función de ventana no se
-- puede usar en el WHERE de la consulta que la calcula: solo se admite en
-- el SELECT y en el ORDER BY.
--
-- Entran todos los pedidos con importe conocido. Los que no lo tienen
-- quedan fuera porque una fila con puesto y sin importe no es un puesto:
-- ordenar por un valor desconocido no significa nada. El NULLS LAST de la
-- ventana los mandaría al final; el WHERE los saca del todo, que es lo
-- que corresponde.
--
-- El ranking va completo, sin recortar. El enunciado pide el ranking y
-- no un podio, así que la respuesta son las 4.571 filas con importe
-- conocido, cada una con el puesto que le toca dentro de su categoría.
-- La extensión A de abajo muestra la cabeza de cada una, que es la parte
-- que se lee para decidir.
SELECT categoria, puesto, pedido_id, importe
FROM (
    SELECT v.categoria,
           v.pedido_id,
           v.importe,
           RANK() OVER (PARTITION BY v.categoria
                        ORDER BY v.importe DESC NULLS LAST) AS puesto
    FROM ventas_limpias v
    WHERE v.importe IS NOT NULL
) AS r
ORDER BY categoria, puesto, pedido_id;

-- PUNTO 4, extensión A. La cabeza del ranking, que es el tramo que se
-- usa para decidir. El corte va sobre el puesto y no sobre la cantidad de
-- filas: RANK le da el mismo puesto a los empatados, así que menor o
-- igual a tres devuelve los puestos hasta el tercero con todos sus
-- empatados adentro, en lugar de cortar un empate por la mitad. Acá el
-- primer puesto está compartido en las cinco categorías, de modo que
-- cada una devuelve tres filas con los puestos 1, 1 y 3, sin puesto 2.
--
-- Se proyecta también el origen del precio, porque es la columna que
-- explica el empate.
SELECT categoria, puesto, pedido_id, importe, origen_del_precio
FROM (
    SELECT v.categoria,
           v.pedido_id,
           v.importe,
           v.origen_del_precio,
           RANK() OVER (PARTITION BY v.categoria
                        ORDER BY v.importe DESC NULLS LAST) AS puesto
    FROM ventas_limpias v
    WHERE v.importe IS NOT NULL
) AS r
WHERE puesto <= 3
ORDER BY categoria, puesto, pedido_id;

-- PUNTO 4, extensión B. El mismo ranking sobre los pedidos con precio
-- original. Un importe imputado equivale al precio de lista por la
-- cantidad, que es la cota superior del artículo, de manera que domina a
-- cualquier venta suya con descuento. Las ventas sin descuento lo
-- igualan, y de ahí salen los empates del primer puesto; contra el
-- ranking filtrado se ve cuántos puestos se mueven por esa causa. La
-- comparación es el motivo de dejar las dos salidas y no aplicar el
-- filtro en silencio sobre el ranking pedido.
SELECT categoria, puesto, pedido_id, cliente_id, cantidad, importe, origen_del_precio
FROM (
    SELECT v.categoria,
           v.pedido_id,
           v.cliente_id,
           v.cantidad,
           v.importe,
           v.origen_del_precio,
           RANK() OVER (PARTITION BY v.categoria
                        ORDER BY v.importe DESC NULLS LAST) AS puesto
    FROM ventas_limpias v
    WHERE v.origen_del_precio = 'Precio original'
) AS r
WHERE puesto <= 3
ORDER BY categoria, puesto, pedido_id;

-- PUNTO 4, extensión C. Ranking de productos dentro de cada categoría.
-- El ranking de pedidos responde lo pedido, pero como decisión de
-- negocio rinde poco: cada fila es una compra suelta. Agrupando por producto
-- aparece de qué artículos depende cada categoría, con lo cual se puede
-- decidir abastecimiento. El puesto se calcula con RANK por el mismo
-- motivo que en el punto 4.
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
    -- desconocida. Aparecen igual en el punto 3, que mide unidades.
    HAVING sum(v.importe) IS NOT NULL
),
ranking AS (
    -- La segunda CTE existe por la misma restricción del lenguaje que
    -- obligó a la subconsulta del punto 4.
    SELECT categoria,
           nombre,
           unidades,
           facturacion,
           RANK() OVER (PARTITION BY categoria ORDER BY facturacion DESC) AS puesto,
           round(100.0 * facturacion
                 / NULLIF(SUM(facturacion) OVER (PARTITION BY categoria), 0), 1)
                                                                AS pct_de_su_categoria
    FROM facturacion_por_producto
)
-- Se muestran cuatro puestos y no tres: en Librería el artículo de alta
-- rotación cae justo en el cuarto, y sin él la comparación entre
-- categorías se lee al revés de lo que dice el dato.
SELECT categoria, puesto, nombre, unidades, facturacion, pct_de_su_categoria
FROM ranking
WHERE puesto <= 4
ORDER BY categoria, puesto, nombre;

-- PUNTO 4, extensión D. Cuántos productos entran al ranking anterior y
-- cuántas unidades quedaron fuera del denominador en cada categoría. El
-- dato hace falta para leer los porcentajes con la reserva que
-- corresponde: donde se excluyeron más unidades, el primer puesto tiene
-- más aire.
--
-- Va también la facturación que entra al denominador de cada categoría,
-- porque sin ella las unidades excluidas no se pueden pesar: excluir cien
-- unidades de una categoría que factura cuatro millones no es lo mismo
-- que excluirlas de una que factura ocho.
--
-- El recuento de productos arranca en el catálogo, con LEFT JOIN hacia
-- la vista, para que una categoría que no vendiera nada aparezca con
-- ceros en lugar de desaparecer: una consulta que informa exclusiones no
-- puede excluir en silencio. Del lado de las ventas usa la vista y no
-- las tablas, para no volver a escribir el COALESCE de la limpieza en un
-- segundo lugar: la etiqueta origen_del_precio ya distingue las filas
-- que el ranking no puede usar.
SELECT pr.categoria,
       count(DISTINCT v.producto_id)
            FILTER (WHERE v.origen_del_precio <> 'Sin precio disponible')
                                                        AS productos_en_el_ranking,
       count(DISTINCT pr.producto_id)                   AS productos_del_catalogo,
       COALESCE(sum(v.cantidad)
            FILTER (WHERE v.origen_del_precio = 'Sin precio disponible'), 0)
                                                        AS unidades_fuera_del_calculo,
       COALESCE(sum(v.importe), 0)                      AS facturacion_en_el_ranking
FROM productos pr
LEFT JOIN ventas_limpias v ON v.producto_id = pr.producto_id
GROUP BY pr.categoria
ORDER BY unidades_fuera_del_calculo DESC, pr.categoria;


-- ---------------------------------------------------------------------
-- PREGUNTA ADICIONAL 1. Segmentación de clientes en cuartiles con NTILE(4)
-- ---------------------------------------------------------------------
-- El enunciado no pide esta pregunta. Va para llegar a las cinco
-- preguntas de negocio que pide el documento del módulo, y no reemplaza
-- ni modifica ninguno de los cuatro puntos. Devuelve cada cliente con su
-- cuartil de gasto.
--
-- Los cortes salen de la propia distribución y no de un umbral escrito a
-- mano, que envejece mal en cuanto cambia el volumen del negocio.
--
-- Va LEFT JOIN desde clientes por el mismo motivo que el punto 3: los
-- que nunca compraron son un hallazgo, no un hueco de carga. Y quedan en
-- una etiqueta propia en lugar de caer dentro del cuarto cuartil, porque
-- el problema de ellos no es gastar poco sino no haber empezado. El
-- PARTITION BY sobre (pedidos = 0) es lo que los aparta antes de repartir.
--
-- Caso borde: un cliente con pedidos pero con todos los importes
-- desconocidos entraría acá con gasto cero y no en Sin actividad. Y como
-- NTILE reparte los empates entre los grupos, si hubiera varios así no
-- caerían todos en el último cuartil: se distribuirían, y alguno podría
-- salir rotulado entre los que más gastan. En este dataset no ocurre; si
-- ocurriera habría que darles una tercera etiqueta, porque el problema
-- de ellos no es el monto sino que no se midió.
WITH gasto_por_cliente AS (
    SELECT c.cliente_id,
           c.nombre,
           count(v.pedido_id)           AS pedidos,
           COALESCE(sum(v.importe), 0)  AS gasto
    FROM clientes c
    LEFT JOIN ventas_limpias v ON v.cliente_id = c.cliente_id
    GROUP BY c.cliente_id, c.nombre
),
clasificados AS (
    SELECT cliente_id,
           nombre,
           pedidos,
           gasto,
           CASE WHEN pedidos = 0 THEN 0
                ELSE NTILE(4) OVER (PARTITION BY (pedidos = 0)
                                    ORDER BY gasto DESC, cliente_id)
           END AS cuartil
    FROM gasto_por_cliente
)
-- La etiqueta de salida se llama clasificacion para dejar el nombre
-- cuartil libre: así el ORDER BY de abajo usa el entero y se lee sin
-- ambigüedad. Con el mismo nombre en los dos lados PostgreSQL resolvería
-- igual contra la columna de entrada, porque el nombre está dentro de
-- una expresión, pero el que lee el código tendría que saberlo.
SELECT cliente_id,
       nombre,
       gasto,
       CASE cuartil WHEN 0 THEN 'Sin actividad'
                    WHEN 1 THEN 'Cuartil 1, los que más gastan'
                    WHEN 2 THEN 'Cuartil 2'
                    WHEN 3 THEN 'Cuartil 3'
                    ELSE        'Cuartil 4, los que menos gastan'
       END AS clasificacion
FROM clasificados
-- Los sin actividad van al final y no al principio: el listado se lee
-- de mayor a menor gasto, y encabezarlo con diez ceros lo vuelve confuso.
ORDER BY CASE WHEN cuartil = 0 THEN 5 ELSE cuartil END, gasto DESC, cliente_id;

-- PREGUNTA ADICIONAL 1, extensión A. El resumen por cuartil, que es lo
-- que se lee para decidir dónde poner el esfuerzo comercial.
WITH gasto_por_cliente AS (
    SELECT c.cliente_id,
           count(v.pedido_id)           AS pedidos,
           -- El denominador del importe medio son los pedidos con
           -- importe conocido, igual que en el punto 1 y en la
           -- pregunta adicional 2.
           count(v.importe)             AS pedidos_con_importe,
           COALESCE(sum(v.importe), 0)  AS gasto
    FROM clientes c
    LEFT JOIN ventas_limpias v ON v.cliente_id = c.cliente_id
    GROUP BY c.cliente_id
),
clasificados AS (
    SELECT cliente_id,
           pedidos,
           pedidos_con_importe,
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
       sum(pedidos_con_importe) AS pedidos_con_importe,
       sum(gasto)               AS facturacion,
       round(100.0 * sum(gasto) / NULLIF(SUM(sum(gasto)) OVER (), 0), 1) AS pct_facturacion,
       round(sum(gasto) / NULLIF(sum(pedidos_con_importe), 0), 2) AS importe_medio_por_pedido,
       -- Los extremos de cada grupo dicen si el corte del NTILE cae en
       -- un quiebre real de la distribución o en el medio de una
       -- pendiente suave. De eso depende que el grupo se pueda
       -- tratar como un segmento comercial.
       max(gasto)               AS gasto_maximo,
       min(gasto)               AS gasto_minimo
FROM clasificados
GROUP BY cuartil
ORDER BY cuartil;

-- PREGUNTA ADICIONAL 1, extensión B. Dónde está el quiebre real de la
-- distribución. NTILE corta por cantidad de clientes, que no tiene por
-- qué coincidir con el lugar donde el gasto se desploma. La consulta
-- busca el salto más grande entre un cliente y el siguiente y reporta
-- qué hay a cada lado, para poder decidir sobre cuántos clientes se arma
-- un programa comercial.
WITH gasto_por_cliente AS (
    SELECT c.cliente_id, sum(v.importe) AS gasto
    FROM clientes c
    JOIN ventas_limpias v ON v.cliente_id = c.cliente_id
    GROUP BY c.cliente_id
),
ordenados AS (
    -- NULLS LAST porque en DESC los nulos van primero: un cliente con
    -- pedidos pero con todos los importes desconocidos encabezaría la
    -- distribución y se reportaría como el quiebre.
    SELECT cliente_id, gasto,
           ROW_NUMBER() OVER (ORDER BY gasto DESC NULLS LAST, cliente_id) AS puesto,
           LEAD(gasto) OVER (ORDER BY gasto DESC NULLS LAST, cliente_id)  AS gasto_siguiente
    FROM gasto_por_cliente
),
quiebre AS (
    SELECT puesto, gasto, gasto_siguiente
    FROM ordenados
    WHERE gasto_siguiente IS NOT NULL
    ORDER BY gasto - gasto_siguiente DESC, puesto
    LIMIT 1
)
-- La consulta arranca en quiebre y no en ordenados: si no hubiera
-- quiebre, por ejemplo con un solo cliente, no devuelve nada en lugar de
-- devolver una fila de ceros, que se leería como que la cartera no está
-- concentrada. Un agregado sin GROUP BY siempre devuelve una fila, así
-- que filtrar con un WHERE no alcanzaría.
SELECT q.puesto                              AS clientes_arriba_del_quiebre,
       q.gasto                               AS ultimo_gasto_antes_del_quiebre,
       q.gasto_siguiente                     AS primer_gasto_despues,
       round((SELECT sum(o.gasto) FROM ordenados o WHERE o.puesto <= q.puesto), 2)
                                             AS facturacion_arriba,
       round(100.0 * (SELECT sum(o.gasto) FROM ordenados o WHERE o.puesto <= q.puesto)
             / NULLIF((SELECT sum(o.gasto) FROM ordenados o), 0), 1)
                                             AS pct_arriba,
       (SELECT count(*) FROM ordenados o WHERE o.puesto > q.puesto) AS clientes_abajo
FROM quiebre q;

-- PREGUNTA ADICIONAL 1, extensión C. Los dos clientes que quedan a cada
-- lado del corte del NTILE, con sus pedidos y su ticket, para poder
-- juzgar si esa frontera es un dato o una casualidad. Mismo criterio que
-- la extensión B del punto 1, donde se mira la frontera del quinto
-- puesto.
WITH gasto_por_cliente AS (
    SELECT c.cliente_id,
           c.nombre,
           count(v.pedido_id)          AS pedidos,
           count(v.importe)            AS pedidos_con_importe,
           COALESCE(sum(v.importe), 0) AS gasto
    FROM clientes c
    LEFT JOIN ventas_limpias v ON v.cliente_id = c.cliente_id
    GROUP BY c.cliente_id, c.nombre
),
clasificados AS (
    SELECT cliente_id,
           nombre,
           pedidos,
           pedidos_con_importe,
           gasto,
           CASE WHEN pedidos = 0 THEN 0
                ELSE NTILE(4) OVER (PARTITION BY (pedidos = 0)
                                    ORDER BY gasto DESC, cliente_id)
           END AS cuartil
    FROM gasto_por_cliente
)
-- Los dos se eligen por posición dentro de su cuartil y no por valor de
-- gasto: si dos clientes empataran justo en el borde, un filtro por
-- igualdad devolvería cuatro filas o más y la consulta dejaría de
-- responder lo que promete.
, bordes AS (
    SELECT cliente_id, nombre, cuartil, pedidos, pedidos_con_importe, gasto,
           ROW_NUMBER() OVER (PARTITION BY cuartil
                              ORDER BY gasto ASC, cliente_id DESC)  AS desde_abajo,
           ROW_NUMBER() OVER (PARTITION BY cuartil
                              ORDER BY gasto DESC, cliente_id ASC)  AS desde_arriba
    FROM clasificados
    WHERE cuartil IN (1, 2)
)
SELECT cliente_id,
       nombre,
       cuartil,
       pedidos,
       gasto,
       round(gasto / NULLIF(pedidos_con_importe, 0), 2) AS ticket_promedio,
       gasto - LEAD(gasto) OVER (ORDER BY gasto DESC, cliente_id) AS diferencia_con_el_siguiente
FROM bordes
WHERE (cuartil = 1 AND desde_abajo = 1)
   OR (cuartil = 2 AND desde_arriba = 1)
ORDER BY gasto DESC, cliente_id;

-- PREGUNTA ADICIONAL 1, extensión D. Quiénes son los que nunca
-- compraron. La pregunta que sigue naturalmente es si se trata de un
-- problema de captación vieja o de altas recientes que no convirtieron, y
-- eso lo contesta la fecha de alta.
SELECT c.cliente_id,
       c.nombre,
       c.segmento,
       c.fecha_alta,
       (SELECT max(fecha_alta) FROM clientes) - c.fecha_alta AS dias_desde_la_ultima_alta
FROM clientes c
WHERE NOT EXISTS (SELECT 1 FROM pedidos p WHERE p.cliente_id = c.cliente_id)
ORDER BY c.fecha_alta DESC, c.cliente_id;


-- ---------------------------------------------------------------------
-- PREGUNTA ADICIONAL 2. La facturación por canal de venta
-- ---------------------------------------------------------------------
-- Tampoco la pide el enunciado, va por el mismo motivo que la anterior.
-- El canal y lo que facturó, que es el corte con el que después se puede
-- preguntar si la diferencia entre canales es de volumen o de calidad de
-- venta.
SELECT canal,
       sum(importe) AS facturacion
FROM ventas_limpias
GROUP BY canal
ORDER BY facturacion DESC, canal;

-- PREGUNTA ADICIONAL 2, extensión A. El mismo corte con lo que hace
-- falta para saber si un canal vende distinto o solamente vende más: el
-- ticket promedio y de qué antigüedad de cliente viene la plata. Sirve
-- para repartir presupuesto comercial, porque un canal que trae volumen
-- de clientes nuevos y otro que sostiene a los históricos piden
-- inversiones distintas.
--
-- El cruce por segmento se arma con FILTER sobre la misma pasada en lugar
-- de tres consultas separadas.
SELECT v.canal,
       count(*)                                              AS pedidos,
       -- Mismo criterio que en el punto 1 para el denominador
       -- del promedio.
       count(v.importe)                                      AS pedidos_con_importe,
       sum(v.cantidad)                                       AS unidades,
       round(avg(v.importe), 2)                              AS ticket_promedio,
       sum(v.importe)                                        AS facturacion,
       round(100.0 * sum(v.importe) / NULLIF(SUM(sum(v.importe)) OVER (), 0), 1)
                                                             AS pct_del_total,
       sum(v.importe) FILTER (WHERE c.segmento = 'Histórico')  AS de_historicos,
       sum(v.importe) FILTER (WHERE c.segmento = 'Recurrente') AS de_recurrentes,
       sum(v.importe) FILTER (WHERE c.segmento = 'Nuevo')      AS de_nuevos,
       round(100.0 * sum(v.importe) FILTER (WHERE c.segmento = 'Nuevo')
             / NULLIF(sum(v.importe), 0), 1)                 AS pct_de_nuevos
FROM ventas_limpias v
JOIN clientes c ON c.cliente_id = v.cliente_id
GROUP BY v.canal
ORDER BY facturacion DESC, v.canal;


-- #####################################################################
-- CIERRE
-- #####################################################################

-- Nota sobre los índices. estructura.sql crea tres y justifica por qué
-- esos y no más; acá se muestra qué hace el planificador con ellos, para
-- no dejar la afirmación sin evidencia. Va con COSTS OFF, que quita las
-- estimaciones de costo y de filas y deja solo los nodos, que es lo que
-- se quiere comparar; los tiempos no se piden porque dependen de la
-- máquina y no del plan.
EXPLAIN (COSTS OFF)
SELECT sum(importe) FROM ventas_limpias
WHERE fecha_pedido BETWEEN DATE '2025-01-01' AND DATE '2025-01-31';

EXPLAIN (COSTS OFF)
SELECT DATE_TRUNC('month', fecha_pedido), sum(importe) FROM ventas_limpias
GROUP BY 1;

-- ANEXO. Las comparaciones que el informe menciona, ejecutadas.
-- Cada una de estas tres cosas estaba afirmada en el texto y hasta acá
-- había que creerla; van con su salida al lado para que no haya que
-- hacerlo.
--
-- Primero, el contrafáctico del punto 3: qué devolvería la consulta de
-- los tres productos menos vendidos con INNER JOIN en lugar de LEFT
-- JOIN. La diferencia es la respuesta entera, no un matiz.
SELECT pr.producto_id,
       pr.nombre,
       sum(p.cantidad) AS unidades_vendidas
FROM productos pr
JOIN pedidos p ON p.producto_id = pr.producto_id
GROUP BY pr.producto_id, pr.nombre
ORDER BY unidades_vendidas ASC, pr.producto_id ASC
LIMIT 3;

-- Lo mismo para la primera pregunta adicional: con INNER JOIN los diez
-- clientes que nunca compraron no aparecen, y el padrón que se segmenta
-- pasa de 200 a 190.
SELECT count(*) AS clientes_con_left_join
FROM clientes c
WHERE TRUE
UNION ALL
SELECT count(DISTINCT c.cliente_id)
FROM clientes c
JOIN ventas_limpias v ON v.cliente_id = c.cliente_id;

-- Y la concentración que los comentarios del generador afirman, medida:
-- cuánto pesan los veinticinco primeros clientes y los ocho artículos de
-- mayor rotación sobre el total de pedidos.
SELECT count(*)                                              AS pedidos_totales,
       count(*) FILTER (WHERE cliente_id <= 25)              AS de_los_25_primeros_clientes,
       round(100.0 * count(*) FILTER (WHERE cliente_id <= 25)
             / NULLIF(count(*), 0), 1)                       AS pct_clientes,
       count(*) FILTER (WHERE producto_id <= 8)              AS de_los_8_de_mas_rotacion,
       round(100.0 * count(*) FILTER (WHERE producto_id <= 8)
             / NULLIF(count(*), 0), 1)                       AS pct_productos
FROM pedidos;

-- Y los dos planes que justifican los índices de las claves foráneas,
-- que no se usan en los cruces sino en las consultas de existencia del
-- punto 3 y de la primera pregunta adicional.
EXPLAIN (COSTS OFF)
SELECT count(*) FROM productos pr
WHERE NOT EXISTS (SELECT 1 FROM pedidos p WHERE p.producto_id = pr.producto_id);

EXPLAIN (COSTS OFF)
SELECT count(*) FROM clientes c
WHERE NOT EXISTS (SELECT 1 FROM pedidos p WHERE p.cliente_id = c.cliente_id);

-- Cifras de cierre, para contrastar los totales contra los que cita el
-- README.
SELECT count(*)                    AS pedidos_analizados,
       count(importe)              AS con_importe_conocido,
       sum(importe)                AS facturacion_total,
       count(DISTINCT cliente_id)  AS clientes_con_compras,
       count(DISTINCT producto_id) AS productos_vendidos
FROM ventas_limpias;
