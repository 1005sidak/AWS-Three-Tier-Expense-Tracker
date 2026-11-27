// Database connection pool for Amazon RDS (MySQL).
// Connection details come from environment variables (see .env.example),
// loaded by the systemd service so no secrets live in the code.
const mysql = require("mysql2/promise");

const pool = mysql.createPool({
  host: process.env.DB_HOST,
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME || "expensedb",
  waitForConnections: true,
  connectionLimit: 10,
});

// Creates the table on first start, so no manual SQL step is needed.
async function init() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS transactions (
      id          INT AUTO_INCREMENT PRIMARY KEY,
      description VARCHAR(255)   NOT NULL,
      amount      DECIMAL(10, 2) NOT NULL,
      category    VARCHAR(50)    NOT NULL DEFAULT 'Other',
      created_at  TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
    )`);
}

module.exports = { pool, init };
