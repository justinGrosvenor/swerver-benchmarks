// Fastify (Node) reference on the HttpArena route vocabulary. Single process,
// single JS thread — same footprint as the Express and Bun entries.
//   PORT=3003 DATASET_PATH=./data/dataset.json STATIC_DIR=./data/static node servers/fastify.mjs
import Fastify from "fastify";
import fastifyStatic from "@fastify/static";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const datasetPath = process.env.DATASET_PATH ?? join(root, "data", "dataset.json");
const staticDir = resolve(process.env.STATIC_DIR ?? join(root, "data", "static"));

let dataset = [];
try {
  dataset = JSON.parse(readFileSync(datasetPath, "utf8"));
} catch {}

// Disable logging so it doesn't skew the benchmark, matching the others.
const app = Fastify({ logger: false });

const sumQuery = (q) =>
  Object.values(q).reduce((s, v) => {
    const n = parseInt(v, 10);
    return Number.isNaN(n) ? s : s + n;
  }, 0);

app.get("/pipeline", (_req, reply) => reply.type("text/plain").send("ok"));

app.get("/baseline11", (req, reply) => reply.type("text/plain").send(String(sumQuery(req.query))));

app.get("/json/:count", (req, reply) => {
  let count = parseInt(req.params.count, 10);
  if (!(count > 0)) count = 0;
  if (count > dataset.length) count = dataset.length;
  const m = parseInt(req.query.m ?? "1", 10) || 1;
  const items = new Array(count);
  for (let i = 0; i < count; i++) {
    const d = dataset[i];
    items[i] = { ...d, total: d.price * d.quantity * m };
  }
  reply.send({ items, count });
});

// Static under /static, mirroring swerver's native /static/ prefix.
app.register(fastifyStatic, { root: staticDir, prefix: "/static/" });

const port = Number(process.env.PORT ?? 3003);
app.listen({ host: "127.0.0.1", port }).then(() => console.log(`fastify on http://127.0.0.1:${port}`));
