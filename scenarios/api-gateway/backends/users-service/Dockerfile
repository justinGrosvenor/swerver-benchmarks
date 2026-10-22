FROM node:22.23.4-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914
WORKDIR /app
COPY package.json .
RUN npm install --production
COPY server.js .
EXPOSE 3001
CMD ["node", "server.js"]
