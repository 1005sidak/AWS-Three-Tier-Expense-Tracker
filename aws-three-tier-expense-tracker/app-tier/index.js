// App tier: REST API for the expense tracker.
// Runs on EC2 instances in private subnets, behind the internal ALB.
const express = require("express");
const os = require("os");
const { pool, init } = require("./db");

const app = express();
const PORT = Number(process.env.PORT || 4000);
const HOST = os.hostname();

app.use(express.json());

// Tag every response with the app server that handled it (shows load balancing in the demo).
app.use((req, res, next) => {
  res.set("X-App-Server", HOST);
  next();
});

// Health check used by the internal ALB target group.
app.get("/health", (req, res) => res.json({ status: "ok", server: HOST }));

// Readiness check that also verifies the database connection.
app.get("/health/db", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ok", database: "reachable", server: HOST });
  } catch (err) {
    res.status(500).json({ status: "error", database: err.code || err.message, server: HOST });
  }
});

// List all transactions.
app.get("/transaction", async (req, res) => {
  try {
    const [rows] = await pool.query(
      "SELECT id, description, amount, category, created_at FROM transactions ORDER BY id DESC"
    );
    res.json({ server: HOST, transactions: rows });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "Could not read transactions" });
  }
});

// Add a transaction.
app.post("/transaction", async (req, res) => {
  const { description, amount, category } = req.body || {};
  const value = Number(amount);
  if (!description || !String(description).trim() || !Number.isFinite(value) || value <= 0) {
    return res.status(400).json({ error: "Description and a positive amount are required" });
  }
  try {
    const [result] = await pool.query(
      "INSERT INTO transactions (description, amount, category) VALUES (?, ?, ?)",
      [String(description).trim().slice(0, 255), value.toFixed(2), String(category || "Other").slice(0, 50)]
    );
    res.status(201).json({ id: result.insertId, server: HOST });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "Could not save transaction" });
  }
});

// Delete one transaction.
app.delete("/transaction/:id", async (req, res) => {
  try {
    const [result] = await pool.query("DELETE FROM transactions WHERE id = ?", [Number(req.params.id)]);
    if (result.affectedRows === 0) return res.status(404).json({ error: "Not found" });
    res.json({ deleted: Number(req.params.id), server: HOST });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "Could not delete transaction" });
  }
});

// Delete all transactions.
app.delete("/transaction", async (req, res) => {
  try {
    await pool.query("DELETE FROM transactions");
    res.json({ deleted: "all", server: HOST });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "Could not delete transactions" });
  }
});

// CPU-heavy endpoint used only for the auto-scaling demo (see scripts/loadtest.js).
app.get("/compute", (req, res) => {
  const ms = Math.min(Number(req.query.ms) || 100, 1000);
  const end = Date.now() + ms;
  let x = 0;
  while (Date.now() < end) x += Math.sqrt(Math.random());
  res.json({ server: HOST, burnedMs: ms });
});

init()
  .then(() => console.log("Database ready"))
  .catch((err) => console.error("Database init failed (will retry on requests):", err.message))
  .finally(() => app.listen(PORT, () => console.log(`API listening on port ${PORT} (${HOST})`)));
