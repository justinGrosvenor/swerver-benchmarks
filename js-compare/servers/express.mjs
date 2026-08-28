// Express (Node) reference on the HttpArena route vocabulary, so it lines up
// with the vendored HttpArena Bun entry and the swerverts app.
//   PORT=3001 DATASET_PATH=./data/dataset.json STATIC_DIR=./data/static node servers/express.mjs
import express from "express";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const datasetPath = process.env.DATASET_PATH ?? join(root, "data", "dataset.json");
const staticDir = process.env.STATIC_DIR ?? join(root, "data", "static");

let dataset = [];
try {
  dataset = JSON.parse(readFileSync(datasetPath, "utf8"));
} catch {}

const app = express();
app.use(express.json());

const sumQuery = (q) =>
  Object.values(q).reduce((s, v) => {
    const n = parseInt(v, 10);
    return Number.isNaN(n) ? s : s + n;
  }, 0);

app.get("/pipeline", (_req, res) => res.type("text/plain").send("ok"));

app.get("/baseline11", (req, res) => res.type("text/plain").send(String(sumQuery(req.query))));

app.get("/json/:count", (req, res) => {
  let count = parseInt(req.params.count, 10);
  if (!(count > 0)) count = 0;
  if (count > dataset.length) count = dataset.length;
  const m = parseInt(req.query.m ?? "1", 10) || 1;
  const items = new Array(count);
  for (let i = 0; i < count; i++) {
    const d = dataset[i];
    items[i] = { ...d, total: d.price * d.quantity * m };
  }
  res.json({ items, count });
});

// Static under /static, mirroring swerver's native /static/ prefix.
app.use("/static", express.static(staticDir));

const port = Number(process.env.PORT ?? 3001);
app.listen(port, () => console.log(`express on http://127.0.0.1:${port}`));
