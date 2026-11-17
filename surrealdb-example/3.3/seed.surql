-- Test dataset for the Kasten blueprint (under 5 KB).
-- Covers what a restore has to bring back: schema, an index, a function,
-- plain records and graph edges (RELATE).
DEFINE TABLE product SCHEMAFULL;
DEFINE FIELD name  ON product TYPE string;
DEFINE FIELD price ON product TYPE number;
DEFINE INDEX product_name ON product FIELDS name UNIQUE;

DEFINE TABLE customer SCHEMALESS;
DEFINE FUNCTION fn::order_total($c: record<customer>) { RETURN math::sum((SELECT VALUE out.price * qty FROM ordered WHERE in = $c)); };

CREATE product:1 SET name = 'kettle',  price = 25;
CREATE product:2 SET name = 'toaster', price = 40;
CREATE product:3 SET name = 'blender', price = 60;
CREATE product:4 SET name = 'mixer',   price = 120;
CREATE product:5 SET name = 'grinder', price = 35;

CREATE customer:alice SET name = 'Alice', city = 'Paris';
CREATE customer:bob   SET name = 'Bob',   city = 'Leeds';
CREATE customer:chen  SET name = 'Chen',  city = 'Lyon';

RELATE customer:alice->ordered->product:1 SET qty = 2;
RELATE customer:alice->ordered->product:3 SET qty = 1;
RELATE customer:bob->ordered->product:2   SET qty = 1;
RELATE customer:bob->ordered->product:4   SET qty = 1;
RELATE customer:chen->ordered->product:5  SET qty = 3;
