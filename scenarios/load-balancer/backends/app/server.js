const express = require('express');
const app = express();

const INSTANCE_ID = process.env.INSTANCE_ID || 'unknown';
let requestCount = 0;

app.get('/health', (req, res) => res.json({ status: 'ok', instance: INSTANCE_ID }));

app.get('/', (req, res) => {
  requestCount++;
  res.json({ instance: INSTANCE_ID, requests: requestCount });
});

app.get('/info', (req, res) => {
  res.json({
    instance: INSTANCE_ID,
    requests: requestCount,
    uptime: process.uptime(),
    memory: process.memoryUsage().rss,
  });
});

app.listen(3000, () => console.log(`app instance ${INSTANCE_ID} listening on 3000`));
