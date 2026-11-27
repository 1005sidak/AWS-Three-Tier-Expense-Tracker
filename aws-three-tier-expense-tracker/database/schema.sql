-- Database tier: schema for Amazon RDS (MySQL).
-- The API creates this table automatically on first start (app-tier/db.js).
-- This file is kept for documentation and for manual setup if needed.

CREATE DATABASE IF NOT EXISTS expensedb;
USE expensedb;

CREATE TABLE IF NOT EXISTS transactions (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  description VARCHAR(255)   NOT NULL,
  amount      DECIMAL(10, 2) NOT NULL,
  category    VARCHAR(50)    NOT NULL DEFAULT 'Other',
  created_at  TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

-- Optional sample data
INSERT INTO transactions (description, amount, category) VALUES
  ('Mess bill', 3500.00, 'Food'),
  ('Bus pass', 600.00, 'Travel'),
  ('Cloud Computing textbook', 450.00, 'Books');
