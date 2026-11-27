// Front-end logic. All API calls go to /api/..., which Nginx on the web tier
// forwards to the internal ALB in front of the app tier.
const API = "/api";

const rowsEl = document.getElementById("rows");
const totalEl = document.getElementById("total");
const msgEl = document.getElementById("message");

function showMessage(text, type) {
  msgEl.textContent = text;
  msgEl.className = "message " + (type || "");
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

async function loadTransactions() {
  try {
    const res = await fetch(`${API}/transaction`);
    if (!res.ok) throw new Error(`API returned ${res.status}`);
    const data = await res.json();
    document.getElementById("app-server").textContent = data.server || "unknown";
    const list = data.transactions || [];
    let total = 0;
    rowsEl.innerHTML = list.length
      ? list.map((t) => {
          total += Number(t.amount);
          const date = new Date(t.created_at).toLocaleDateString("en-IN");
          return `<tr>
            <td>${date}</td>
            <td>${escapeHtml(t.description)}</td>
            <td>${escapeHtml(t.category)}</td>
            <td class="num">${Number(t.amount).toFixed(2)}</td>
            <td><button class="link" data-id="${t.id}">Delete</button></td>
          </tr>`;
        }).join("")
      : `<tr><td colspan="5" class="empty">No expenses yet. Add one above.</td></tr>`;
    totalEl.textContent = total.toFixed(2);
  } catch (err) {
    rowsEl.innerHTML = `<tr><td colspan="5" class="empty">Could not reach the API (${escapeHtml(err.message)}).</td></tr>`;
  }
}

async function loadServerInfo() {
  try {
    document.getElementById("web-server").textContent = (await (await fetch("/whoami")).text()).trim();
  } catch { document.getElementById("web-server").textContent = "unknown"; }
  try {
    const res = await fetch(`${API}/health/db`);
    const data = await res.json();
    document.getElementById("db-status").textContent = data.database;
    document.getElementById("app-server").textContent = data.server;
  } catch { document.getElementById("db-status").textContent = "unreachable"; }
}

document.getElementById("expense-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const body = {
    description: document.getElementById("description").value,
    amount: document.getElementById("amount").value,
    category: document.getElementById("category").value,
  };
  try {
    const res = await fetch(`${API}/transaction`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || res.status);
    showMessage(`Saved (handled by ${data.server})`, "ok");
    e.target.reset();
    loadTransactions();
  } catch (err) {
    showMessage(`Could not save: ${err.message}`, "error");
  }
});

rowsEl.addEventListener("click", async (e) => {
  const id = e.target.dataset.id;
  if (!id) return;
  await fetch(`${API}/transaction/${id}`, { method: "DELETE" });
  loadTransactions();
});

document.getElementById("clear-all").addEventListener("click", async () => {
  await fetch(`${API}/transaction`, { method: "DELETE" });
  showMessage("All transactions deleted", "ok");
  loadTransactions();
});

document.getElementById("refresh").addEventListener("click", () => {
  loadServerInfo();
  loadTransactions();
});

loadServerInfo();
loadTransactions();
