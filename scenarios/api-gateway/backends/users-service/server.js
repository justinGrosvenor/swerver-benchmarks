const express = require('express');
const app = express();
app.use(express.json());

const users = [
  { id: 1, name: 'Alice', email: 'alice@example.com' },
  { id: 2, name: 'Bob', email: 'bob@example.com' },
  { id: 3, name: 'Charlie', email: 'charlie@example.com' },
];
let nextId = 4;

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'users' }));

app.get('/users', (req, res) => res.json(users));

app.get('/users/:id', (req, res) => {
  const user = users.find(u => u.id === parseInt(req.params.id));
  if (!user) return res.status(404).json({ error: 'User not found' });
  res.json(user);
});

app.post('/users', (req, res) => {
  const user = { id: nextId++, name: req.body.name, email: req.body.email };
  users.push(user);
  res.status(201).json(user);
});

app.listen(3001, () => console.log('users-service listening on 3001'));
