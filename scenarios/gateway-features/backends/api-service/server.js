const express = require('express');
const app = express();
app.use(express.json());

const users = [
  { id: 1, name: 'Alice', email: 'alice@example.com', role: 'admin' },
  { id: 2, name: 'Bob', email: 'bob@example.com', role: 'user' },
  { id: 3, name: 'Charlie', email: 'charlie@example.com', role: 'user' },
];

app.get('/health', (req, res) => res.json({ status: 'ok' }));

// Small JSON — tests routing/auth overhead
app.get('/users', (req, res) => res.json(users));

app.get('/users/:id', (req, res) => {
  const user = users.find(u => u.id === parseInt(req.params.id));
  if (!user) return res.status(404).json({ error: 'not found' });
  res.json(user);
});

app.post('/users', (req, res) => {
  res.status(201).json({ id: 99, ...req.body });
});

// Large JSON — tests compression savings
const catalog = Array.from({ length: 200 }, (_, i) => ({
  id: i + 1,
  name: `Product ${i + 1}`,
  description: `This is a detailed description for product number ${i + 1}. It contains enough text to make compression worthwhile and demonstrate bandwidth savings at the gateway level.`,
  price: parseFloat((Math.random() * 100 + 1).toFixed(2)),
  category: ['electronics', 'clothing', 'food', 'books', 'tools'][i % 5],
  tags: ['sale', 'new', 'popular', 'limited'].slice(0, (i % 4) + 1),
}));

app.get('/catalog', (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.json(catalog);
});

// Slow endpoint — makes cache value obvious
app.get('/expensive', (req, res) => {
  setTimeout(() => {
    res.json({ result: 'computed', timestamp: Date.now(), data: catalog.slice(0, 10) });
  }, 50);
});

// Version header — verifies traffic split routing
app.get('/version', (req, res) => {
  res.json({ version: process.env.APP_VERSION || 'v1' });
});

// Echo endpoint for body validation tests
app.post('/validate', (req, res) => {
  res.json({ received: req.body });
});

const port = parseInt(process.env.PORT || '3000');
app.listen(port, () => console.log(`api-service (${process.env.APP_VERSION || 'v1'}) on ${port}`));
