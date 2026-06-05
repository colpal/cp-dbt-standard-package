# `iceberg_overrides.sql` — Technical Reference

## Overview

`iceberg_overrides.sql` is a Jinja macro file in `cp-dbt-standard-package` that globally intercepts dbt's native Snowflake materialization macros. Its primary purpose is to make all model output **safe for Snowflake Native Iceberg tables** by dynamically inspecting and recasting column types that Iceberg does not support or that require explicit precision.

It is organized into five sections, each addressing a distinct compatibility concern.

---

## Sections

### Section 1 — DDL Contract Bypass

**Macros:** `get_table_columns_and_constraints`, `render_raw_columns_constraints` (and their `default__` / `snowflake__` variants)

dbt's contract enforcement injects `COLUMN col_name col_type NOT NULL` DDL into `CREATE TABLE` statements when a model has `contract: enforced`. Snowflake Iceberg tables do not support inline column-level constraints in DDL. These overrides return an empty string, effectively silencing contract injection before it reaches Snowflake.

---

### Section 2 — Incremental Staging Type Override

**Macro:** `snowflake__get_tmp_relation_type`

When dbt builds an incremental model, it first creates a temporary staging relation to hold the new rows before merging or deleting+inserting them. By default, dbt uses a **view** as the temp relation for most strategies.

Iceberg tables cannot be merged from a view — the staging relation must be a **table**. This macro forces `return("table")` for any model linked to a Snowflake Native Iceberg catalog (`catalog_type == 'BUILT_IN'` or `config.get('catalog_name')` is set), ensuring the staging relation is always a temporary table.

Non-Iceberg models fall through to the original dbt logic unchanged.

---

### Section 3 — Materialization Overrides (Safe Temp Table Routing)

**Macros:** `snowflake__create_table_as`, `snowflake__create_view_as`, `snowflake__get_create_view_as_sql`, `snowflake__get_create_table_as_sql`, `snowflake__get_create_iceberg_table_as_sql`, `snowflake__create_iceberg_table_as`

These macros intercept every DDL path dbt uses to materialize a model. The pattern for table materializations is:

1. Run `iceberg_type_safe_wrap(compiled_code)` to get a cast-safe SELECT.
2. Execute `CREATE OR REPLACE TEMPORARY TABLE <relation>__dbt_pre AS <safe_sql>` — a regular (non-Iceberg) temp table that accepts all types.
3. Pass `SELECT * FROM <relation>__dbt_pre` as the body of the real `CREATE ICEBERG TABLE` DDL.

This two-step approach ensures type coercions happen in a permissive staging table before being read into the strict Iceberg target.

**`snowflake__create_table_as` skips this two-step path when `temporary=True`** — temporary relations are staging helpers for incremental models and do not need Iceberg type casting.

---

### Section 4 — Contract Column Assertion Bypass

**Macros:** `get_assert_columns_equivalent`, `default__get_assert_columns_equivalent`, `snowflake__get_assert_columns_equivalent`

dbt's Python-level contract validation compares columns returned by the model against the YAML contract definition. Because Iceberg tables recast some types (e.g. `TIMESTAMP_TZ` → `TIMESTAMP_LTZ`), this comparison would always fail. These overrides return an empty string to silence the assertion entirely.

---

### Section 5 — `iceberg_type_safe_wrap` (The Wrapper Engine)

**Macro:** `iceberg_type_safe_wrap(compiled_code)`

This is the core engine. It dynamically introspects the output columns of any compiled SQL and wraps it with explicit `CAST` expressions for every type that Snowflake Native Iceberg cannot store or requires in a specific precision.

#### How It Works

1. **Create introspection view** — executes `CREATE OR REPLACE VIEW <temp_view> AS (<compiled_code>)` in the current schema. The closing `)` is placed on its own line to prevent trailing SQL comments in `compiled_code` from commenting it out.
2. **Describe the view** — runs `DESCRIBE VIEW <temp_view>` to get the resolved column names and types.
3. **Classify columns** — builds a list of columns that need casting and a complete list of all columns with their types.
4. **Drop the view** — executes `DROP VIEW IF EXISTS <temp_view>` immediately after introspection.
5. **Early exit** — if no columns need casting, returns `compiled_code` unchanged (zero overhead).
6. **Generate safe SELECT** — builds a new `SELECT` that wraps each column in the appropriate `CAST`, then returns `SELECT <casts> FROM (<compiled_code>) AS __iceberg_type_safe_source`.

#### Type Mapping

| Snowflake source type | Cast applied | Reason |
|---|---|---|
| `TIMESTAMP_LTZ` | `TIMESTAMP_LTZ(6)` | Explicit precision required |
| `TIMESTAMP_NTZ` | `TIMESTAMP_NTZ(6)` | Explicit precision required |
| `TIMESTAMP_TZ` | `TIMESTAMP_LTZ(6)` | Iceberg does not support `TZ`; converted to `LTZ` |
| `TIMESTAMP` (unqualified) | `TIMESTAMP_NTZ(6)` | Ambiguous; normalized to `NTZ` |
| `TIME` | `TIME(6)` | Explicit precision required |
| `ARRAY` / `OBJECT` | `TO_JSON(...) AS VARCHAR(16777216)` | Not supported as Iceberg stored column types |
| `VARCHAR` / `STRING` | `VARCHAR(16777216)` | Snowflake Iceberg max VARCHAR is 16 MB |
| `NUMBER` / `DECIMAL` / `NUMERIC` (unspecified or `38,0`) | `NUMBER(38, 0)` | Unqualified NUMBER defaults may be rejected |
| `VARIANT` | **no cast** | Supported natively by Snowflake Iceberg |
| All other types | **no cast** | Passed through as-is |

---

## FAQs

### Will this trigger on non-Iceberg models?

**Yes — `iceberg_type_safe_wrap` runs on every model** because the materialization overrides in Section 3 are global. However, the macro performs a live `DESCRIBE VIEW` and only injects casts for columns that actually need them. For models with no type mismatches the early-exit path fires and the original SQL is returned unchanged with minimal overhead (two lightweight DDL statements).

If you need to restrict the override to Iceberg-only models, the `snowflake__get_tmp_relation_type` macro already gates on `catalog_name` / `catalog_type`, but Section 3 macros do not — this is intentional since the type coercions are harmless on regular tables.

---

### Why does `TIMESTAMP_TZ` get converted to `TIMESTAMP_LTZ`?

Snowflake Native Iceberg (built-in catalog) maps Iceberg's `timestamptz` type to `TIMESTAMP_LTZ`. Storing a `TIMESTAMP_TZ` column directly is not supported. The cast to `TIMESTAMP_LTZ(6)` preserves timezone offset semantics while conforming to the Iceberg type system.

---

### Why is `VARIANT` not cast but `ARRAY` and `OBJECT` are?

Snowflake Native Iceberg supports `VARIANT` as a stored column type. Casting it to `VARCHAR` via `TO_JSON()` would break downstream semi-structured access patterns like `column:field::TYPE`.

`ARRAY` and `OBJECT` are **not** supported as Iceberg stored column types. They must be serialized to JSON string (`VARCHAR`) for the `CREATE ICEBERG TABLE` DDL to succeed.

---

### What happens with columns that use semi-structured path notation (`:`) in their name?

`DESCRIBE VIEW` can return column names containing `:` when the view references a semi-structured accessor path inline (e.g. `inherent_risk:value`). Wrapping such a name in `CAST("col:field" AS ...)` is misinterpreted by Snowflake as `GET(col, 'field')`, which fails with `Invalid argument types for function 'GET'`. The macro detects any column name containing `:` and passes it through without a cast.

---

### Why is VARCHAR capped at 16,777,216?

That is Snowflake's maximum `VARCHAR` length for Iceberg tables (16 MB). The original codebase used `VARCHAR(134217728)` (128 MB), which exceeded this limit and caused `unexpected '<EOF>'` SQL compilation errors.

---

### What if a model's SQL ends with a trailing comment (`---` or `--`)?

A trailing single-line comment at the end of `compiled_code` would have commented out the `)` that closes the `CREATE OR REPLACE VIEW ... AS (...)` introspection wrapper, causing an `unexpected '<EOF>'` error. The fix places the closing `)` on its own new line, so a trailing comment only affects the last line of `compiled_code` itself, never the wrapper syntax.

---

### Does this affect temporary tables used by incremental models?

No. `snowflake__create_table_as` skips the two-step wrap-and-cast path when `temporary=True`. Temporary staging relations for incremental models are regular Snowflake tables (not Iceberg), accept all types natively, and do not need type coercion.

---

### What is the `__dbt_pre` table?

A short-lived `TEMPORARY TABLE` created in the same session as the dbt run, named `<relation>__dbt_pre`. It holds the output of the cast-safe SELECT. The final `CREATE ICEBERG TABLE ... AS SELECT * FROM __dbt_pre` then reads from it. Being a temporary table it is automatically dropped at session end and does not persist.

---

## Edge Cases Captured & Mitigated

| Edge case | Symptom without fix | Mitigation |
|---|---|---|
| `ARRAY` / `OBJECT` output columns | `Unsupported data type 'ARRAY' for iceberg tables` | Cast to `TO_JSON(...) AS VARCHAR(16777216)` |
| `VARIANT` output columns | `Invalid argument types for function 'GET'` on downstream `:field` access | Skip cast entirely — VARIANT is Iceberg-native |
| `TIMESTAMP_TZ` output columns | DDL rejected by Iceberg type system | Cast to `TIMESTAMP_LTZ(6)` |
| Unqualified `TIMESTAMP` columns | Ambiguous precision may be rejected | Normalize to `TIMESTAMP_NTZ(6)` |
| `VARCHAR` exceeding 16 MB | `unexpected '<EOF>'` compilation error | Cap cast at `VARCHAR(16777216)` |
| Trailing `---` / `--` comment in model SQL | `unexpected '<EOF>'` in introspection view | Closing `)` on its own line |
| Temporary incremental staging tables | Oversized generated SQL, unnecessary overhead | Guard: skip wrap when `temporary=True` |
| Semi-structured column name aliases (`:` in name) | `Invalid argument types for function 'GET'` | Guard: skip cast when column name contains `:` |
| Jinja loop variable scoping (`is_array_or_object`) | ARRAY columns not cast despite detection in first loop | Recalculate `is_array_or_object` inside the cast loop |
| dbt YAML contract DDL injection | `CREATE ICEBERG TABLE` fails with inline constraint syntax | Override `get_table_columns_and_constraints` to return empty string |
| dbt Python contract column assertion | Build failure due to type name mismatch after casting | Override `get_assert_columns_equivalent` to return empty string |
| Iceberg incremental models using view as temp relation | Merge/delete+insert fails — can't merge from a view into Iceberg | Force `tmp_relation_type = "table"` for Iceberg models |
