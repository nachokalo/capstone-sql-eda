-- =====================================================================
-- Proyecto Capstone: Análisis Exploratorio de Datos en PostgreSQL
-- estructura.sql - Creación del esquema y carga del dataset
-- Ignacio Kalogiannidis - PostgreSQL 16
-- =====================================================================
--
-- Ejecución:
--   createdb capstone_project
--   psql -d capstone_project -f estructura.sql
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

-- 3.1. Clientes
-- Las altas van todas en 2023, antes del primer pedido, para que ningún
-- cliente figure comprando antes de existir.
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
    DATE '2023-01-01' + (g * 3 % 360)
FROM generate_series(1, 200) AS g;

-- 3.2. Productos
-- Costo y precio de lista salen del mismo valor base, así que ningún
-- artículo cuesta más de lo que se vende. El margen va del cuarenta al
-- sesenta por ciento según el artículo: con un margen único se podría
-- despejar el precio de lista dividiendo el costo, y los productos que
-- no lo tienen cargado dejarían de ser un dato faltante real.
INSERT INTO productos (producto_id, nombre, categoria, precio_lista, costo, stock, activo)
SELECT
    g,
    'Producto ' || lpad(g::text, 3, '0'),
    (ARRAY['Electrónica','Hogar','Indumentaria','Deportes',
           'Librería'])[1 + (g % 5)],
    -- Seis artículos quedan sin precio de lista. El módulo 9 los reparte
    -- entre las cinco categorías, y la guarda sobre los ocho primeros
    -- evita que el hueco caiga sobre los artículos de mayor rotación.
    CASE WHEN g % 9 = 4 AND g > 8 THEN NULL
         ELSE round((200 + (g * 137 % 9800))::numeric, 2)
    END,
    round((200 + (g * 137 % 9800))::numeric * (0.40 + (g % 5) * 0.05), 2),
    10 + (g * 7 % 40),
    (g % 12 <> 0)
FROM generate_series(1, 60) AS g;

-- 3.3. Pedidos
-- La fecha usa el resto de multiplicar por 367, coprimo con 730, así que
-- recorre los 730 días del período sin repetir hasta agotarlos. El total
-- es 5110 porque son siete vueltas exactas: con un número que no fuera
-- múltiplo del período, los pedidos de la vuelta incompleta se
-- amontonarían sobre los primeros meses y simularían una caída inexistente.
--
-- Sobre esa base pareja se descarta uno de cada once pedidos del segundo
-- año. El divisor once es coprimo con los que asignan cliente, producto,
-- cantidad y canal, de manera que el recorte cae parejo sobre todos ellos
-- en lugar de sacar de más los pedidos caros.
INSERT INTO pedidos (pedido_id, cliente_id, producto_id, cantidad,
                     precio_unitario, fecha_pedido, canal)
SELECT
    s.g,
    -- Cartera desbalanceada: los primeros veinticinco clientes se quedan
    -- con algo más del cuarenta por ciento de los pedidos. El módulo 190
    -- deja además sin ninguna compra a los últimos diez del padrón.
    CASE WHEN s.g % 3 = 0 THEN 1 + (s.g * 7 % 25)
         ELSE 1 + (s.g * 13 % 190) END,
    -- La demanda tampoco se reparte pareja entre los artículos: ocho
    -- productos de alta rotación se llevan cerca del cuarenta por ciento
    -- de los pedidos y el resto se distribuye sobre los demás.
    CASE WHEN s.g % 10 < 3 THEN 1 + (s.g * 7 % 8)
         ELSE 1 + (s.g * 17 % 54) END,
    -- Cantidad y canal salen de divisores coprimos entre sí, 3 y 7, y
    -- coprimos también con los que asignan cliente, producto y fecha. Si
    -- compartieran divisor, cada canal quedaría atado a una cantidad fija
    -- y la facturación por canal mediría el divisor en lugar del negocio.
    1 + (s.g % 3),
    NULL,          -- se completa en 3.4, que necesita el precio del producto
    DATE '2024-01-01' + s.dia,
    -- La mezcla de canales es despareja: el marketplace concentra tres de
    -- cada siete pedidos y la web uno de cada siete.
    (ARRAY['Marketplace','Marketplace','Marketplace',
           'App','App','Teléfono','Web'])[1 + (s.g % 7)]
FROM (
    SELECT g, (g * 367 % 730) AS dia
    FROM generate_series(1, 5110) AS g
) AS s
WHERE NOT (s.dia >= 365 AND s.g % 11 = 4);

-- 3.4. Precios cobrados
-- El precio unitario es el de lista menos un descuento de hasta el nueve
-- y medio por ciento, en pasos de una décima. El divisor 97 es primo y
-- por lo tanto coprimo con todos los demás del generador, y da noventa y
-- siete descuentos distintos: con pocos escalones, cientos de pedidos
-- terminarían con el importe exactamente igual y cualquier ranking de
-- pedidos devolvería empates masivos en lugar de un orden.
--
-- Que el precio cobrado y el de lista vivan en la misma escala es lo que
-- hace que más adelante completar un precio faltante con el de lista sea
-- una estimación razonable: si el cobrado fuera varias veces el de lista,
-- ese COALESCE subestimaría la facturación.
UPDATE pedidos p
SET precio_unitario = round(pr.precio_lista * (1 - (p.pedido_id % 97) / 1000.0), 2)
FROM productos pr
WHERE pr.producto_id = p.producto_id
  AND pr.precio_lista IS NOT NULL;

-- 3.5. Los huecos que resuelve la limpieza
-- Pedidos que perdieron el precio en la importación. Como el producto sí
-- tiene precio de lista, son recuperables.
UPDATE pedidos SET precio_unitario = NULL WHERE pedido_id % 12 = 5;

-- Pedidos sin fecha. Estos no se recuperan por ningún camino: nada en el
-- resto de la fila permite estimar cuándo ocurrió la venta.
UPDATE pedidos SET fecha_pedido = NULL WHERE pedido_id % 33 = 0;

-- A esos se suman, por arrastre, los pedidos de los seis productos sin
-- precio de lista. Son el caso más difícil, porque tampoco se pueden
-- deducir del costo: el margen varía por artículo y no se conoce.


-- ---------------------------------------------------------------------
-- 4. ÍNDICES
-- ---------------------------------------------------------------------
-- Solo tres. Indexar de más cuesta en cada escritura, y sobre las casi
-- cinco mil filas de este dataset el planificador resuelve la mayoría de
-- las consultas con recorrido secuencial igual; están pensados para el
-- volumen al que crece la tabla.

-- Las dos claves foráneas, que es por donde pedidos se une con el resto.
-- PostgreSQL indexa la clave primaria pero no las foráneas.
CREATE INDEX idx_pedidos_cliente  ON pedidos (cliente_id);
CREATE INDEX idx_pedidos_producto ON pedidos (producto_id);

-- La fecha, que es por donde filtra y agrupa la serie temporal. B-Tree
-- porque mantiene un orden total sobre el valor, y ese orden es lo que
-- permite resolver un rango recorriendo solo el tramo que corresponde.
CREATE INDEX idx_pedidos_fecha ON pedidos (fecha_pedido);

-- Canal y categoría quedan sin indexar: con cuatro y cinco valores
-- distintos sobre miles de filas filtran demasiado poco.

ANALYZE clientes;
ANALYZE productos;
ANALYZE pedidos;


-- ---------------------------------------------------------------------
-- 5. VERIFICACIÓN DE LA CARGA
-- ---------------------------------------------------------------------
-- Confirma de entrada que los datos entraron completos y que los tipos
-- quedaron declarados como corresponde.

SELECT 'clientes'  AS tabla, count(*) AS filas FROM clientes
UNION ALL
SELECT 'productos', count(*) FROM productos
UNION ALL
SELECT 'pedidos',   count(*) FROM pedidos
ORDER BY tabla;

-- Cobertura temporal de la carga: cuántos días distintos tienen al menos
-- un pedido y entre qué fechas. Si quedaran días vacíos, cualquier
-- lectura por semana o por día de la semana saldría distorsionada.
SELECT count(DISTINCT fecha_pedido) AS dias_con_pedidos,
       min(fecha_pedido)            AS primer_pedido,
       max(fecha_pedido)            AS ultimo_pedido
FROM pedidos;

SELECT table_name  AS tabla,
       column_name AS columna,
       data_type   AS tipo,
       numeric_precision AS precision,
       numeric_scale     AS escala
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('clientes','productos','pedidos')
  AND (data_type IN ('date','numeric') OR column_name LIKE '%fecha%')
ORDER BY table_name, ordinal_position;
