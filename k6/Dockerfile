FROM grafana/k6:latest

# Copy scenarios and helpers
COPY scenarios/ /scenarios/
COPY lib/ /lib/

WORKDIR /scenarios

# Default entrypoint runs specified scenario
ENTRYPOINT ["k6", "run"]
CMD ["throughput.js"]
