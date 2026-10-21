-- Fake sample data only. Runs inside the database named by POSTGRES_DB.
CREATE TABLE customers (
  id SERIAL PRIMARY KEY,
  name VARCHAR(80) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE
);

CREATE TABLE products (
  id SERIAL PRIMARY KEY,
  sku VARCHAR(20) NOT NULL UNIQUE,
  title VARCHAR(80) NOT NULL,
  price_cents INT NOT NULL
);

CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(id),
  placed_at TIMESTAMP NOT NULL
);

CREATE TABLE order_items (
  id SERIAL PRIMARY KEY,
  order_id INT NOT NULL REFERENCES orders(id),
  product_id INT NOT NULL REFERENCES products(id),
  quantity INT NOT NULL
);

INSERT INTO customers (name, email) VALUES
  ('Ada Example', 'ada@example.test'),
  ('Ben Sample', 'ben@example.test'),
  ('Cleo Demo', 'cleo@example.test'),
  ('Dev Placeholder', 'dev@example.test');

INSERT INTO products (sku, title, price_cents) VALUES
  ('SKU-001', 'Widget', 1250),
  ('SKU-002', 'Gadget', 3400),
  ('SKU-003', 'Gizmo', 799),
  ('SKU-004', 'Doohickey', 5600),
  ('SKU-005', 'Thingamajig', 210);

INSERT INTO orders (customer_id, placed_at) VALUES
  (1, '2026-01-05 10:00:00'),
  (1, '2026-02-11 14:30:00'),
  (2, '2026-02-12 09:15:00'),
  (3, '2026-03-01 16:45:00'),
  (4, '2026-03-02 08:05:00'),
  (2, '2026-03-20 12:00:00');

INSERT INTO order_items (order_id, product_id, quantity) VALUES
  (1, 1, 2), (1, 3, 1),
  (2, 2, 1),
  (3, 4, 1), (3, 5, 10),
  (4, 1, 1), (4, 2, 2),
  (5, 3, 3),
  (6, 5, 4), (6, 4, 1);
