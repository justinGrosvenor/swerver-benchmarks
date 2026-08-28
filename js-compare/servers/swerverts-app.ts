// swerverts app on the HttpArena route vocabulary. swerver (Zig) is the front
// process; /pipeline, /baseline11, and /json/:count run in a Bun server on a
// unix socket that swerver proxies to. /static/:name is served by swerver
// natively from staticRoot (no TS crossing).
//   SWERVER_BIN=~/swerver/zig-out/bin/swerver PORT=8080 \
//   DATASET_PATH=./data/dataset.json STATIC_DIR=./data/static \
//   bun run servers/swerverts-app.ts

import { Swerver } from "swerverts";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const port = Number(process.env["PORT"] ?? 8080);
const datasetPath = process.env["DATASET_PATH"] ?? join(root, "data", "dataset.json");
const staticDir = process.env["STATIC_DIR"] ?? join(root, "data", "static");

type Item = { id: number; price: number; quantity: number; [k: string]: unknown };
let dataset: Item[] = [];
try {
  dataset = (await Bun.file(datasetPath).json()) as Item[];
} catch {}

const app = new Swerver({ port, staticRoot: staticDir });

app.get("/pipeline", () => new Response("ok", { headers: { "content-type": "text/plain" } }));

app.get("/baseline11", (req) => {
  const q = new URL(req.url).searchParams;
  let sum = 0;
  for (const [, v] of q) {
    const n = parseInt(v, 10);
    if (!Number.isNaN(n)) sum += n;
  }
  return new Response(String(sum), { headers: { "content-type": "text/plain" } });
});

app.get("/json/:count", (req, { params }) => {
  let count = parseInt(params.count, 10);
  if (!(count > 0)) count = 0;
  if (count > dataset.length) count = dataset.length;
  const m = parseInt(new URL(req.url).searchParams.get("m") ?? "1", 10) || 1;
  const items = new Array(count);
  for (let i = 0; i < count; i++) {
    const d = dataset[i]!;
    items[i] = { ...d, total: d.price * d.quantity * m };
  }
  return Response.json({ items, count });
});

const server = await app.start();
console.log(`swerverts on ${server.url}`);

const stop = async () => {
  await server.stop();
  process.exit(0);
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
