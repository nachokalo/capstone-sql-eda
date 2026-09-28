-- =====================================================================
-- Proyecto Capstone: Análisis Exploratorio de Datos en PostgreSQL
-- estructura.sql - Creación del esquema y carga del dataset
-- Ignacio Kalogiannidis - PostgreSQL 16
-- =====================================================================
--
-- Ejecución:
--   createdb capstone_project
--   psql -v ON_ERROR_STOP=1 -d capstone_project -f estructura.sql
--
-- El script se puede correr varias veces sobre la misma base: empieza
-- eliminando todo lo que va a recrear.
--
-- Modelo: tres entidades, quién compra, qué se vende y qué pasó. Cada
-- fila de pedidos es la compra de un producto por un cliente en una
-- fecha. No hay tabla de detalle separada porque ninguna pregunta del
-- análisis necesita agrupar varias líneas bajo un mismo ticket.


-- ---------------------------------------------------------------------
-- 1. LIMPIEZA PREVIA
-- ---------------------------------------------------------------------

-- La vista que crea analisis.sql depende de estas tablas y bloquea el
-- DROP mientras exista, así que se elimina primero.
DROP VIEW IF EXISTS ventas_limpias;

-- Pedidos referencia a las otras dos, de modo que va antes para que las
-- claves foráneas no impidan el borrado.
DROP TABLE IF EXISTS pedidos;
DROP TABLE IF EXISTS productos;
DROP TABLE IF EXISTS clientes;


-- ---------------------------------------------------------------------
-- 2. DEFINICIÓN DE LAS TABLAS
-- ---------------------------------------------------------------------
-- Las fechas van en DATE para poder usar aritmética de fechas y
-- DATE_TRUNC, y para que el motor rechace una fecha imposible en lugar
-- de aceptarla como cadena. El dinero va en NUMERIC y no en punto
-- flotante: NUMERIC es de precisión exacta y el error de redondeo del
-- flotante se vuelve visible al sumar miles de importes.
--
-- El texto va en TEXT y no en VARCHAR(n) porque ninguna de estas
-- columnas tiene un largo máximo que sea regla del negocio, y en
-- PostgreSQL los dos tipos se almacenan igual.

CREATE TABLE clientes (
    cliente_id  INT  PRIMARY KEY,
    nombre      TEXT NOT NULL,
    email       TEXT NOT NULL,
    ciudad      TEXT NOT NULL,
    segmento    TEXT NOT NULL,
    fecha_alta  DATE NOT NULL,
    -- El email identifica al cliente, así que la unicidad se declara en
    -- la base en lugar de confiar en que los datos vengan limpios.
    CONSTRAINT uq_clientes_email  UNIQUE (email),
    CONSTRAINT chk_clientes_email CHECK (email LIKE '%_@_%._%'),
    -- Segmento es un dominio cerrado. Sin este CHECK, un error de carga
    -- crea un segmento nuevo y las agrupaciones dejan de cerrar.
    CONSTRAINT chk_clientes_segmento
        CHECK (segmento IN ('Histórico','Recurrente','Nuevo'))
);

CREATE TABLE productos (
    producto_id  INT           PRIMARY KEY,
    nombre       TEXT          NOT NULL,
    categoria    TEXT          NOT NULL,
    -- Acepta NULL porque el catálogo heredado tiene artículos sin precio
    -- cargado. Es uno de los huecos que resuelve la limpieza.
    precio_lista NUMERIC(10,2),
    costo        NUMERIC(10,2) NOT NULL,
    -- Hace falta para valorizar lo que no rota: sin existencias, sumar
    -- costos unitarios no dice cuánto capital hay quieto.
    stock        INT           NOT NULL,
    activo       BOOLEAN       NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_productos_categoria
        CHECK (categoria IN ('Electrónica','Hogar','Indumentaria',
                             'Deportes','Librería')),
    CONSTRAINT chk_costo_positivo    CHECK (costo > 0),
    CONSTRAINT chk_precio_positivo   CHECK (precio_lista IS NULL OR precio_lista > 0),
    CONSTRAINT chk_stock_no_negativo CHECK (stock >= 0)
);

CREATE TABLE pedidos (
    pedido_id       INT  PRIMARY KEY,
    cliente_id      INT  NOT NULL REFERENCES clientes(cliente_id),
    producto_id     INT  NOT NULL REFERENCES productos(producto_id),
    cantidad        INT  NOT NULL,
    -- Precio y fecha aceptan NULL porque así llegan del importador. No
    -- se declaran NOT NULL para no rechazar la fila y perder la venta:
    -- el hueco queda visible y se trata en la etapa de limpieza.
    precio_unitario NUMERIC(10,2),
    fecha_pedido    DATE,
    canal           TEXT NOT NULL,
    CONSTRAINT chk_pedidos_canal
        CHECK (canal IN ('Web','App','Teléfono','Marketplace')),
    CONSTRAINT chk_cantidad_positiva CHECK (cantidad > 0),
    -- Un importe negativo es un error de carga, no un pedido.
    CONSTRAINT chk_precio_unitario_positivo
        CHECK (precio_unitario IS NULL OR precio_unitario > 0)
);


-- ---------------------------------------------------------------------
-- 3. CARGA DEL DATASET
-- ---------------------------------------------------------------------
-- Los datos se generan con generate_series y aritmética modular, sin
-- random(), para que cualquiera que ejecute el script obtenga las mismas
-- filas y pueda reproducir los números del README.
--
-- La carga va dentro de una transacción: si algo fallara en el medio, la
-- base quedaría con las tablas creadas y los datos a la mitad, y el
-- script de análisis correría sobre eso sin que nada avisara.
BEGIN;

-- 3.1. Clientes
-- Las altas van todas en 2023, antes del primer pedido, para que ningún
-- cliente figure comprando antes de existir. Van en orden de id, así que
-- los últimos del padrón son las altas más recientes.
INSERT INTO clientes (cliente_id, nombre, email, ciudad, segmento, fecha_alta)
SELECT
    g,
    (ARRAY['Ana','Bruno','Carla','Diego','Elena','Facundo','Gabriela',
           'Hernán','Irina','Joaquín'])[1 + (g % 10)] || ' ' ||
    (ARRAY['Álvarez','Benítez','Cardozo','Domínguez','Escobar',
           'Ferreyra','Giménez','Herrera','Ibarra'])[1 + (g % 9)],
    'cliente' || g || '@correo.com',
    (ARRAY['Buenos Aires','Córdoba','Rosario','Mendoza','La Plata',
           'Mar del Plata'])[1 + (g % 6)],
    -- El segmento sale de la antigüedad: los primeros cuarenta son los
    -- clientes fundacionales del negocio.
    CASE WHEN g <= 40  THEN 'Histórico'
         WHEN g <= 120 THEN 'Recurrente'
         ELSE 'Nuevo' END,
    DATE '2023-01-01' + ((g - 1) * 9 / 5)
FROM generate_series(1, 200) AS g;

-- 3.2. Productos
-- Costo y precio de lista salen del mismo valor base, así que ningún
-- artículo cuesta más de lo que se vende.
--
-- Dos recaudos para que los artículos sin precio cargado se parezcan a
-- un dato faltante, o sea para que no se despejen leyendo las tres
-- tablas. El precio base es cuadrático sobre el número de artículo y da
-- varias vueltas sobre el módulo 9800, de modo que no crece de forma
-- ordenada: interpolar entre los dos vecinos del catálogo se equivoca
-- entre el cuarenta y nueve y más de dos mil por ciento en cuatro de los
-- seis casos, y en los otros dos queda a menos de dos puntos por
-- casualidad. El segundo recaudo es el margen, que toma un valor propio
-- en cada artículo, así que el de al lado tampoco lo delata.
--
-- Los dos recaudos valen frente a las tablas y no frente a este archivo:
-- quien lea estas dos líneas tiene la fórmula y recupera cualquier
-- precio. Es inevitable en un dataset generado y está declarado en el
-- README.
INSERT INTO productos (producto_id, nombre, categoria, precio_lista, costo, stock, activo)
SELECT
    g,
    'Producto ' || lpad(g::text, 3, '0'),
    (ARRAY['Electrónica','Hogar','Indumentaria','Deportes',
           'Librería'])[1 + (g % 5)],
    -- Seis artículos quedan sin precio de lista. El módulo 9 es coprimo
    -- con el 5 de la categoría, de modo que el hueco se reparte: cuatro
    -- rubros con uno cada uno y Deportes con dos. La condición sobre los
    -- ocho primeros lo mantiene lejos de los artículos de mayor
    -- rotación.
    CASE WHEN g % 9 = 4 AND g > 8 THEN NULL
         ELSE round((200 + ((g * g * 97 + g * 41) % 9800))::numeric, 2)
    END,
    round((200 + ((g * g * 97 + g * 41) % 9800))::numeric
          * (0.40 + (g * 37 % 60) * 0.003), 2),
    -- El módulo 41 es primo, de modo que el stock no queda emparejado
    -- con la categoría ni con el precio.
    10 + (g * 11 % 41),
    (g % 12 <> 0)
FROM generate_series(1, 60) AS g;

-- 3.3. Pedidos
-- La fecha sale de g * 367 % 730. El 367 es coprimo con 730, así que
-- recorre los 730 días del período sin repetir ninguno antes de
-- agotarlos todos. Y el total de filas, 5110, es múltiplo exacto de 730:
-- siete vueltas completas. Si no lo fuera, la vuelta incompleta cargaría
-- de más los primeros meses y aparecería una caída que el negocio no
-- tiene.
--
-- Sobre esa base pareja se descartan dos de cada veintitrés pedidos del
-- segundo año, que es la retracción que el escenario simula. El corte va
-- en el día 366 y no en el 365 porque 2024 es bisiesto: contado desde el
-- 1 de enero de 2024, el día 365 todavía es el 31 de diciembre de 2024.
INSERT INTO pedidos (pedido_id, cliente_id, producto_id, cantidad,
                     precio_unitario, fecha_pedido, canal)
SELECT
    s.g,
    -- Cartera desbalanceada: los primeros veinticinco clientes se quedan
    -- con casi la mitad de los pedidos. El módulo 190 deja además sin
    -- ninguna compra a los diez últimos del padrón, que por el orden de
    -- las altas son los diez ingresos más recientes.
    CASE WHEN s.g % 17 < 7 THEN 1 + (s.g * 7 % 25)
         ELSE 1 + (s.g * 13 % 190) END,
    -- La demanda tampoco se reparte pareja entre los artículos: ocho
    -- productos de alta rotación se llevan cerca del cuarenta por ciento
    -- de los pedidos y el resto se distribuye sobre los demás. Los cinco
    -- últimos del catálogo quedan fuera del rango y por eso no registran
    -- ninguna venta.
    CASE WHEN s.g % 13 < 5 THEN 1 + (s.g * 3 % 8)
         ELSE 9 + (s.g * 17 % 47) END,
    -- La cantidad sale del módulo 3, y ninguno de los divisores que
    -- asignan cliente, producto, canal o los huecos de la limpieza es
    -- múltiplo de 3. Si alguno lo fuera, ese atributo quedaría atado a
    -- una cantidad fija y cualquier lectura de unidades o de ticket
    -- promedio mediría el divisor en lugar del negocio.
    1 + (s.g % 3),
    NULL,          -- se completa en 3.4, que necesita el precio del producto
    DATE '2024-01-01' + s.dia,
    -- La mezcla de canales es despareja: el marketplace concentra tres de
    -- cada siete pedidos y la web uno de cada siete. El reparto está
    -- fijado acá, así que la diferencia de volumen entre canales es parte
    -- del escenario y no un hallazgo de los datos.
    (ARRAY['Marketplace','Marketplace','Marketplace',
           'App','App','Teléfono','Web'])[1 + (s.g % 7)]
FROM (
    SELECT g, (g * 367 % 730) AS dia
    FROM generate_series(1, 5110) AS g
) AS s
WHERE NOT (s.dia >= 366 AND s.g % 23 IN (4, 17));

-- 3.4. Precios cobrados
-- El precio unitario es el de lista menos un descuento de hasta el nueve
-- coma seis por ciento, en pasos de una décima. El divisor 97 es primo y
-- por lo tanto coprimo con todos los demás del generador, y da noventa y
-- seis descuentos distintos más el caso sin descuento. Con pocos
-- escalones habría muchos más pedidos con el importe exactamente igual;
-- empates quedan igual, porque dos pedidos del mismo producto, la misma
-- cantidad y el mismo escalón coinciden, pero son grupos chicos y no
-- bloques que se lleven puestos enteros del ranking.
--
-- Que el precio cobrado y el de lista estén en el mismo orden de
-- magnitud es lo que hace que más adelante completar un precio faltante
-- con el de lista sea una estimación razonable. La contracara es que el
-- de lista no lleva descuento, así que esa estimación queda unos puntos
-- por encima del valor que habría tenido el pedido.
UPDATE pedidos p
SET precio_unitario = round(pr.precio_lista * (1 - (p.pedido_id % 97) / 1000.0), 2)
FROM productos pr
WHERE pr.producto_id = p.producto_id
  AND pr.precio_lista IS NOT NULL;

-- 3.5. Los huecos que resuelve la limpieza
-- Pedidos que perdieron el precio en la importación. El divisor 11 es
-- primo, de modo que el hueco no cae sobre una cantidad ni sobre un canal
-- en particular. La mayoría son recuperables, porque su producto sí tiene
-- precio de lista; los que caen sobre un artículo sin precio cargado se
-- suman al grupo irrecuperable, y la etapa de limpieza los separa.
UPDATE pedidos SET precio_unitario = NULL WHERE pedido_id % 11 = 5;

-- Pedidos sin fecha. Estos no se recuperan por ningún camino: nada en el
-- resto de la fila permite estimar cuándo ocurrió la venta. El divisor
-- 31 también es primo y por el mismo motivo.
UPDATE pedidos SET fecha_pedido = NULL WHERE pedido_id % 31 = 0;

-- A esos se suman, por arrastre, los pedidos de los artículos sin precio
-- de lista. Desde las tablas el costo no permite despejar el precio,
-- porque cada artículo tiene su propio margen y ninguna columna lo
-- registra, pero sí permite acotarlo, y de eso se ocupa la etapa de
-- limpieza.

COMMIT;


-- ---------------------------------------------------------------------
-- 4. ÍNDICES
-- ---------------------------------------------------------------------
-- Solo tres. Indexar de más cuesta en cada escritura, y están pensados
-- para el volumen al que crece la tabla y no para el tamaño actual del
-- dataset. La sección de cierre de analisis.sql muestra con EXPLAIN qué
-- hace el planificador con ellos hoy.

-- Las dos claves foráneas, que es por donde pedidos se une con el resto.
-- PostgreSQL indexa la clave primaria pero no las foráneas.
CREATE INDEX idx_pedidos_cliente  ON pedidos (cliente_id);
CREATE INDEX idx_pedidos_producto ON pedidos (producto_id);

-- La fecha, que es por donde el análisis de la serie temporal filtra y
-- agrupa. B-Tree porque mantiene un orden total sobre el valor, y ese
-- orden es lo que permite resolver un rango recorriendo solo el tramo
-- que corresponde.
CREATE INDEX idx_pedidos_fecha ON pedidos (fecha_pedido);

-- Canal y categoría quedan sin indexar: con cuatro y cinco valores
-- distintos sobre miles de filas filtran demasiado poco.

ANALYZE clientes;
ANALYZE productos;
ANALYZE pedidos;


-- ---------------------------------------------------------------------
-- 5. VERIFICACIÓN DE LA CARGA
-- ---------------------------------------------------------------------
-- Confirma de entrada que los datos entraron completos, que los tipos
-- quedaron declarados como corresponde y que no hay inconsistencias
-- entre tablas.

SELECT 'clientes'  AS tabla, count(*) AS filas FROM clientes
UNION ALL
SELECT 'productos', count(*) FROM productos
UNION ALL
SELECT 'pedidos',   count(*) FROM pedidos
ORDER BY tabla;

-- Cobertura temporal de la carga: cuántos días distintos tienen al menos
-- un pedido y entre qué fechas. Si quedaran días vacíos, habría meses
-- con menos días de actividad que otros y la variación mes a mes
-- mediría el calendario además del negocio.
SELECT count(DISTINCT fecha_pedido) AS dias_con_pedidos,
       min(fecha_pedido)            AS primer_pedido,
       max(fecha_pedido)            AS ultimo_pedido
FROM pedidos;

-- Tres controles de integridad que sí pueden fallar, con el resultado
-- escrito al lado para que no haya que deducirlo de la salida.
--
-- Corren después del COMMIT, de manera que un control fallado aborta el
-- script con la carga ya confirmada. Sirven para frenar el análisis, no
-- para revertir la escritura.
--
-- La tabla de abajo los informa, y el bloque que sigue los exige: si uno
-- fallara, el script corta con error en lugar de imprimir ALERTA y
-- seguir. La diferencia importa, porque un control que solo escribe una
-- palabra depende de que alguien la lea.
SELECT 'ningún pedido anterior al alta de su cliente' AS control,
       count(*) AS casos,
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ALERTA' END AS resultado
FROM pedidos p
JOIN clientes c ON c.cliente_id = p.cliente_id
WHERE p.fecha_pedido < c.fecha_alta
UNION ALL
-- Va mayor o igual y no mayor estricto: un artículo que se vende
-- exactamente a su costo tampoco es una venta, así que conviene que
-- dispare la alerta igual que uno que se vende por debajo.
SELECT 'ningún artículo con costo mayor o igual al precio de lista',
       count(*),
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ALERTA' END
FROM productos
WHERE precio_lista IS NOT NULL AND costo >= precio_lista
UNION ALL
SELECT 'ninguna columna de dinero en punto flotante',
       count(*),
       CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ALERTA' END
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('productos','pedidos')
  AND column_name IN ('precio_lista','costo','precio_unitario')
  AND data_type <> 'numeric';

DO $$
DECLARE
    fallas int;
BEGIN
    SELECT count(*) INTO fallas
    FROM pedidos p
    JOIN clientes c ON c.cliente_id = p.cliente_id
    WHERE p.fecha_pedido < c.fecha_alta;
    IF fallas > 0 THEN
        RAISE EXCEPTION 'Hay % pedidos anteriores al alta de su cliente', fallas;
    END IF;

    SELECT count(*) INTO fallas
    FROM productos
    WHERE precio_lista IS NOT NULL AND costo >= precio_lista;
    IF fallas > 0 THEN
        RAISE EXCEPTION 'Hay % artículos con costo mayor o igual al precio de lista', fallas;
    END IF;

    SELECT count(*) INTO fallas
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('productos','pedidos')
      AND column_name IN ('precio_lista','costo','precio_unitario')
      AND data_type <> 'numeric';
    IF fallas > 0 THEN
        RAISE EXCEPTION 'Hay % columnas de dinero fuera de NUMERIC', fallas;
    END IF;

    -- Volumen esperado de la carga. Si el generador cambiara y las
    -- cantidades se movieran, conviene enterarse acá y no al leer un
    -- número raro en el informe.
    IF (SELECT count(*) FROM clientes)  <> 200  THEN RAISE EXCEPTION 'clientes no cargó 200 filas';  END IF;
    IF (SELECT count(*) FROM productos) <> 60   THEN RAISE EXCEPTION 'productos no cargó 60 filas';  END IF;
    IF (SELECT count(DISTINCT fecha_pedido) FROM pedidos) <> 730 THEN
        RAISE EXCEPTION 'la carga no cubre los 730 días del período';
    END IF;
    -- El conteo de pedidos es el denominador de casi todas las cifras
    -- del informe, así que conviene que una corrida que no lo reproduzca
    -- corte acá y no más adelante.
    IF (SELECT count(*) FROM pedidos) <> 4889 THEN
        RAISE EXCEPTION 'pedidos no cargó las 4889 filas esperadas';
    END IF;

    RAISE NOTICE 'Controles pasados: los tres de integridad y los cuatro de volumen.';
END $$;

-- Tipos declarados de las tres tablas, completos. Se listan todas las
-- columnas y no solo las de fecha y dinero, porque parte de lo que hay
-- que verificar es que el texto haya quedado en TEXT.
SELECT table_name  AS tabla,
       column_name AS columna,
       data_type   AS tipo,
       numeric_precision AS digitos,
       numeric_scale     AS escala
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('clientes','productos','pedidos')
ORDER BY table_name, ordinal_position;
