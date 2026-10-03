import os

from flask import Flask, jsonify
from psycopg_pool import ConnectionPool

SUMMARY_QUERY = (
    "select (select count(*) from tasks) as total,"
    " (select count(*) from tasks where status = 'todo') as todo,"
    " (select count(*) from tasks where status = 'doing') as doing,"
    " (select count(*) from tasks where status = 'done') as done"
    " from pg_sleep(0.3)"
)

ACTIVITY_QUERY = (
    "select d::date as day, count(t.id) as created"
    " from generate_series(current_date - 6, current_date, interval '1 day') as d"
    " left join tasks t on t.created_at::date = d::date"
    " group by d order by d"
)

pool = ConnectionPool(
    os.environ.get("DATABASE_URL", "postgresql://tasklog:tasklog@localhost:5432/tasklog"),
    min_size=1,
    max_size=4,
    open=True,
)
app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/readyz")
def readyz():
    with pool.connection(timeout=2.0) as conn:
        conn.execute("select 1")
    return jsonify(status="ok")


@app.get("/api/reports/summary")
def summary():
    with pool.connection() as conn:
        total, todo, doing, done = conn.execute(SUMMARY_QUERY).fetchone()
    return jsonify(total=total, todo=todo, doing=doing, done=done)


@app.get("/api/reports/activity")
def activity():
    with pool.connection() as conn:
        rows = conn.execute(ACTIVITY_QUERY).fetchall()
    return jsonify([{"day": day.isoformat(), "created": created} for day, created in rows])
