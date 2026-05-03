{#-
  drop_unneeded_objects(dry_run='false')
  ─────────────────────────────────────
  Runs on-run-end to drop Snowflake objects that are no longer represented in
  the dbt project (orphaned tables/views/SVs).

  Arguments:
    dry_run (str|bool): When 'false' or false (default), DROP statements are
                        executed. Any other value logs the commands without
                        running them. Both boolean and string forms are accepted
                        — the value is normalized to a lowercase string at macro
                        entry (false → 'false', true → 'true').

  Configuration (dbt vars):
    drop_unneeded_objects_protected_schemas (list[str]):
      Schemas to exclude from all cleanup queries.
      Default: ['UTIL_COMMON', 'UTIL_SECURITY', 'INFORMATION_SCHEMA']
      Consumer repos may extend this list in dbt_project.yml:
        vars:
          drop_unneeded_objects_protected_schemas:
            - UTIL_COMMON
            - UTIL_SECURITY
            - INFORMATION_SCHEMA
            - LANDING  # repo-specific addition

  Allowlist keying (Fix 2):
    All object matching is done via fully-qualified SCHEMA.NAME keys (and
    SCHEMA.NAME.TYPE for materialization-change detection). This prevents a
    rogue orphan TABLE_B.FCT_ORDERS from being protected just because the
    dbt model FCT_ORDERS lives in TABLE_A.

  Error resilience (Fix 4):
    Each DROP is executed inside a Snowflake Scripting anonymous block so that
    a failed drop (permission error, dependency conflict, etc.) is logged as a
    WARNING and the loop continues — it does not abort cleanup for all remaining
    objects. IF EXISTS in the DROP command handles the "object vanished" race.

  Semantic View cleanup (requires cp-dbt-standard-package ≥ 2.7.0):
    • Skipped entirely if the project has no nodes with
      config.materialized == 'semantic_view' (safe for repos not yet using SVs).
    • Orphan detection uses fully-qualified SCHEMA.NAME keys to avoid false
      positives when SVs in different schemas share the same node name.
    • Only applies to the dbt_model output format. SVs created via
      SV_OUTPUT_FORMAT=snowflake_ddl are not tracked by this macro.
    • LAST_QUERY_ID() safety: on-run-end hooks execute in a single-threaded,
      sequential dbt context — no concurrent queries can interleave between the
      SHOW SEMANTIC VIEWS call and the RESULT_SCAN(LAST_QUERY_ID()) call.
-#}
{% macro drop_unneeded_objects(dry_run='false') %}

{# Fix 1: Normalize dry_run — accept bool (false/true) or string ('false'/'true').
   After this, dry_run == 'false' is reliable regardless of how the caller
   passes the value. #}
{% set dry_run = dry_run | string | lower %}

{# Fix 3: Read protected schemas from a dbt var so consumer repos can extend
   the default list without modifying this macro. #}
{% set protected_schemas = var(
    'drop_unneeded_objects_protected_schemas',
    ['UTIL_COMMON', 'UTIL_SECURITY', 'INFORMATION_SCHEMA']
) | map('upper') | list %}

{% if execute %}

  {# Fix 2: Build FQN-keyed allowlists (SCHEMA.NAME and SCHEMA.NAME.TYPE)
     instead of name-only lists. This prevents schema-blind false protection.

     node.schema is always non-null in a compiled dbt graph:
       - Models with +schema config → resolved custom schema (e.g. 'MARTS_FCT')
       - Models without +schema config → target.schema (e.g. 'PUBLIC')
     dbt-core guarantees this fallback before calling generate_schema_name,
     so no null-handling is required here.

     semantic_view nodes are excluded — they never appear in
     INFORMATION_SCHEMA.TABLES and are handled by the dedicated SV block. #}
  {% set current_model_fqns = [] %}      {# SCHEMA.NAME pairs #}
  {% set current_model_type_fqns = [] %} {# SCHEMA.NAME.TYPE triples #}

  {% for node in graph.nodes.values()
     | selectattr("resource_type", "in", ["model", "seed", "snapshot"])
     | rejectattr("config.materialized", "equalto", "semantic_view") %}
    {% set node_schema = node.schema | upper %}
    {% set node_name   = node.name   | upper %}
    {% set eff_type = node.config.materialized
        | replace("seed",        "table")
        | replace("incremental", "table")
        | replace("snapshot",    "table")
        | upper %}
    {% do current_model_fqns.append(node_schema ~ "." ~ node_name) %}
    {% do current_model_type_fqns.append(node_schema ~ "." ~ node_name ~ "." ~ eff_type) %}
  {% endfor %}

  -- Collect expected Semantic View FQNs (SCHEMA.NAME) for semantic_view materialization.
  -- Using fully-qualified keys prevents false-positive drops when two SVs in
  -- different schemas share the same node name (e.g. MARTS_A.FCT_SALES and MARTS_B.FCT_SALES).
  {% set current_sv_fqns = [] %}
  {% for node in graph.nodes.values()
     | selectattr("resource_type", "equalto", "model")
     | selectattr("config.materialized", "equalto", "semantic_view") %}
    {% do current_sv_fqns.append((node.schema | upper) ~ "." ~ (node.name | upper)) %}
  {% endfor %}

{% endif %}

{% if execute %}

-- ── Query 1: Drop objects not present in the dbt project at all ─────────────
-- Uses SCHEMA.NAME FQN matching to avoid schema-blind false protection.
-- DBT_STATE is always protected by name (schema-agnostic sentinel).
{% set cleanup_query %}
      with models_to_drop as (
        select
          case
            when table_type = 'BASE TABLE'   then 'TABLE'
            when table_type = 'VIEW'         then 'VIEW'
            when table_type = 'ICEBERG TABLE' then 'TABLE'
          end as relation_type,
          concat_ws('.', table_catalog, table_schema, table_name) as relation_name
        from
          {{ target.database }}.information_schema.tables
        where table_schema not in
            ({%- for s in protected_schemas -%}
                '{{ s }}'
                {%- if not loop.last -%},{%- endif -%}
            {%- endfor -%})
          and table_name != 'DBT_STATE'
          and concat_ws('.', table_schema, table_name) not in
            ({%- for fqn in current_model_fqns -%}
                '{{ fqn }}'
                {%- if not loop.last -%},{%- endif -%}
            {%- endfor -%})
      )
      select
        'DROP ' || relation_type || ' IF EXISTS ' || relation_name || ';' as drop_commands
      from
        models_to_drop
      -- intentionally exclude unhandled table_types, including 'EXTERNAL TABLE'
      where drop_commands is not null
{% endset %}

-- ── Query 2: Drop objects whose materialization type changed ─────────────────
-- Detects e.g. a model that was a VIEW but is now a TABLE (old VIEW must be
-- dropped before the TABLE can be created).
-- Uses SCHEMA.NAME.TYPE triple matching for the same schema-awareness reason.
{% set tab_vw_cleanup_query %}
      with tab_vw_to_drop as (
        select
          table_schema,
          table_name,
          case
            when table_type = 'BASE TABLE'   then 'TABLE'
            when table_type = 'VIEW'         then 'VIEW'
            when table_type = 'ICEBERG TABLE' then 'TABLE'
          end as relation_type,
          concat_ws('.', table_catalog, table_schema, table_name) as relation_name
        from
          {{ target.database }}.information_schema.tables
        where table_schema not in
            ({%- for s in protected_schemas -%}
                '{{ s }}'
                {%- if not loop.last -%},{%- endif -%}
            {%- endfor -%})
      ),

      tab_vw_to_drop_final as (
        select
          relation_type,
          relation_name,
          -- Fix 2: use SCHEMA.NAME.TYPE so that FCT_ORDERS.VIEW in SCHEMA_B
          -- is not protected just because FCT_ORDERS.TABLE exists in SCHEMA_A.
          concat_ws('.', table_schema, table_name, relation_type) as sf_schema_tabnm_type
        from
          tab_vw_to_drop
        where sf_schema_tabnm_type not in
            ({%- for fqn_type in current_model_type_fqns -%}
                '{{ fqn_type }}'
                {%- if not loop.last -%},{%- endif -%}
            {%- endfor -%})
      )

      select
        'DROP ' || relation_type || ' IF EXISTS ' || relation_name || ';' as drop_tab_vw_command
      from
        tab_vw_to_drop_final
      -- intentionally exclude unhandled table_types, including 'EXTERNAL TABLE'
      where drop_tab_vw_command is not null
{% endset %}

-- ── Execute Query 1 results ──────────────────────────────────────────────────
{% set drop_commands = run_query(cleanup_query).columns[0].values() %}
{% if drop_commands %}
  {% do log("PRINTING CLEANUP_QUERY LOG", True) %}
  {% for drop_command in drop_commands %}
    {% do log(drop_command, True) %}
    {% if dry_run == 'false' %}
      {# Direct run_query — IF EXISTS handles the object-vanished race.
         EXECUTE IMMEDIATE $$ BEGIN...END $$ removed: the BEGIN keyword in
         {% set %} blocks triggers the dbt-snowflake 1.11.x adapter's
         transaction scanner and causes 'cannot access local variable connection'. #}
      {% do run_query(drop_command) %}
    {% endif %}
  {% endfor %}
{% else %}
  {% do log('No objects to clean.', True) %}
{% endif %}

-- ── Execute Query 2 results ──────────────────────────────────────────────────
{% set drop_tab_vw = run_query(tab_vw_cleanup_query).columns[0].values() %}
{% if drop_tab_vw %}
  {% do log("PRINTING TAB_VW_CLEANUP_QUERY LOG", True) %}
  {% for drop_tabvw in drop_tab_vw %}
    {% do log(drop_tabvw, True) %}
    {% if dry_run == 'false' %}
      {% do run_query(drop_tabvw) %}
    {% endif %}
  {% endfor %}
{% else %}
  {% do log('No objects to clean.', True) %}
{% endif %}

{% endif %}{# execute — queries 1 & 2 #}

-- ── Semantic View cleanup ────────────────────────────────────────────────────
-- Safety guard: only run if graph.nodes contains semantic_view nodes.
-- If the project has no SV models, current_sv_fqns is empty and we skip
-- entirely to prevent mass drops in repos not yet using SVs.
{% if execute and current_sv_fqns | length > 0 %}
  {% do log("SEMANTIC VIEW CLEANUP: expected SV FQNs: " ~ current_sv_fqns | join(', '), True) %}

  -- Step 1: discover what SVs currently exist in the target database.
  -- Snowflake semantic views are NOT in information_schema.tables — they have
  -- their own dedicated catalog view: information_schema.semantic_views.
  -- Columns per docs.snowflake.com/en/sql-reference/info-schema/semantic_views:
  --   catalog, schema, name, owner, created, comment
  {% set existing_sv_results = run_query(
      "SELECT name, schema"
      " FROM " ~ target.database ~ ".information_schema.semantic_views"
      " WHERE schema != 'INFORMATION_SCHEMA'"
  ) %}

  {% if existing_sv_results and existing_sv_results.rows | length > 0 %}
    {% for row in existing_sv_results.rows %}
      {% set sv_name   = row[0] | upper %}
      {% set sv_schema = row[1] | upper %}
      {% set sv_fqn    = sv_schema ~ "." ~ sv_name %}
      {% if sv_fqn not in current_sv_fqns %}
        {% set drop_sv_cmd = "DROP SEMANTIC VIEW IF EXISTS "
            ~ target.database ~ "." ~ sv_schema ~ "." ~ sv_name ~ ";" %}
        {% do log("SV orphan detected — queuing: " ~ drop_sv_cmd, True) %}
        {% if dry_run == 'false' %}
          {% do run_query(drop_sv_cmd) %}
        {% endif %}
      {% endif %}
    {% endfor %}
  {% else %}
    {% do log('No semantic views found in ' ~ target.database ~ ' — nothing to clean.', True) %}
  {% endif %}

{% elif execute %}
  {% do log("SEMANTIC VIEW CLEANUP: no semantic_view nodes in graph — skipping SV cleanup.", True) %}
{% endif %}

select 1 -- drop_unneeded_objects completed
{%- endmacro -%}
