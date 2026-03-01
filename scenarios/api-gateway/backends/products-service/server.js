const express = require('express');
const app = express();
app.use(express.json());

const products = [
  { id: 1, name: 'Widget', price: 9.99 },
  { id: 2, name: 'Gadget', price: 24.99 },
  { id: 3, name: 'Doohickey', price: 14.99 },
];
let nextId = 4;

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'products' }));

app.get('/products', (req, res) => res.json(products));

app.get('/products/:id', (req, res) => {
  const product = products.find(p => p.id === parseInt(req.params.id));
  if (!product) return res.status(404).json({ error: 'Product not found' });
  res.json(product);
});

app.post('/products', (req, res) => {
  const product = { id: nextId++, name: req.body.name, price: req.body.price };
  products.push(product);
  res.status(201).json(product);
});

app.listen(3002, () => console.log('products-service listening on 3002'));
