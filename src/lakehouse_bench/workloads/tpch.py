"""Small, format-independent TPC-H workloads."""
import hashlib
import json
from decimal import Decimal

Q1 = """
SELECT l_returnflag, l_linestatus,
       sum(l_quantity) AS sum_qty,
       sum(l_extendedprice) AS sum_base_price,
       sum(l_extendedprice * (1 - l_discount)) AS sum_disc_price,
       sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) AS sum_charge,
       avg(l_quantity) AS avg_qty,
       avg(l_extendedprice) AS avg_price,
       avg(l_discount) AS avg_disc,
       count(*) AS count_order
FROM {table}
WHERE l_shipdate <= DATE '1998-09-02'
GROUP BY l_returnflag, l_linestatus
ORDER BY l_returnflag, l_linestatus
"""


def sql(query, table):
    if query != "q1":
        raise ValueError(f"unsupported TPC-H query: {query}")
    return Q1.format(table=table)


def canonical_value(value):
    if isinstance(value, Decimal):
        value = value.normalize()
        return format(value, "f") if value else "0"
    return str(value)


def checksum(rows):
    canonical = [[canonical_value(value) for value in row] for row in rows]
    payload = json.dumps(canonical, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(payload.encode("ascii")).hexdigest()
