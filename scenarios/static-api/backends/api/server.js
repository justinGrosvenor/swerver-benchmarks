const express = require('express');
const app = express();
app.use(express.json());

const data = [
  { id: 1, title: 'First Item', body: 'Content for the first item' },
  { id: 2, title: 'Second Item', body: 'Content for the second item' },
  { id: 3, title: 'Third Item', body: 'Content for the third item' },
];
let nextId = 4;

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'api' }));

app.get('/data', (req, res) => res.json(data));

app.get('/data/:id', (req, res) => {
  const item = data.find(d => d.id === parseInt(req.params.id));
  if (!item) return res.status(404).json({ error: 'Not found' });
  res.json(item);
});

app.post('/data', (req, res) => {
  const item = { id: nextId++, title: req.body.title, body: req.body.body };
  data.push(item);
  res.status(201).json(item);
});

app.listen(3000, () => console.log('api-service listening on 3000'));
