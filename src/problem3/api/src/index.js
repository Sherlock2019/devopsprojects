const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();

const pool = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER || "postgres",
  password: process.env.DB_PASSWORD || "postgres",
  database: process.env.DB_NAME || "postgres",
  port: Number(process.env.DB_PORT || 5432),
  // FIX: bound the pool and never wait forever for a connection or a query.
  max: Number(process.env.DB_POOL_MAX || 10),
  connectionTimeoutMillis: 2000,
  idleTimeoutMillis: 30000,
  query_timeout: 5000,
});

// FIX: pg emits 'error' on idle clients when Postgres restarts or drops a connection.
// Without a listener Node treats it as an unhandled 'error' event and the process exits
// ("terminating connection due to administrator command"), taking the API down.
pool.on("error", (err) => {
  console.error("postgres idle client error:", err.message);
});

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: Number(process.env.REDIS_PORT || 6379),
  maxRetriesPerRequest: 1,
  connectTimeout: 2000,
});
redis.on("error", (err) => {
  console.error("redis error:", err.message);
});

app.get("/api/users", async (req, res) => {
  try {
    // FIX: pool.query() acquires and always releases the client, even when the query throws.
    // The original pool.connect() + db.release() leaked a connection on every failed query.
    const result = await pool.query("SELECT NOW()");

    // Redis is a best-effort side write; its failure should not fail the request.
    redis.set("last_call", Date.now()).catch((err) => {
      console.error("redis set failed:", err.message);
    });

    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error(err.message);
    res.status(503).json({ ok: false, error: "database unavailable" });
  }
});

// Liveness: the process is up and serving HTTP.
app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

// Readiness: dependencies are reachable.
app.get("/api/ready", async (req, res) => {
  try {
    await pool.query("SELECT 1");
    await redis.ping();
    res.json({ ready: true });
  } catch (err) {
    res.status(503).json({ ready: false, error: err.message });
  }
});

const server = app.listen(3000, () => console.log("API running on 3000"));

// Graceful shutdown so `docker compose stop` / rolling restarts do not cut requests mid-flight.
function shutdown(signal) {
  console.log(`${signal} received, shutting down`);
  server.close(async () => {
    await Promise.allSettled([pool.end(), redis.quit()]);
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
