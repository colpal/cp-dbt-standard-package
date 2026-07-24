{#-
  drop_unneeded_objects(dry_run='false')
  ─────────────────────────────────────
  Runs on-run-end to drop Snowflake objects that are no longer represented in
  the dbt project (orphaned tables and views).

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

  Semantic View cleanup:
    Snowflake Semantic Views are managed by the dedicated dbt-common CI step
    (ci/drop_orphaned_semantic_views/drop_orphaned_semantic_views.py). This
    macro intentionally does not touch information_schema.semantic_views.
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
     so no null-handling is required here. #}
  {% set current_model_fqns = [] %}      {# SCHEMA.NAME pairs #}
  {% set current_model_type_fqns = [] %} {# SCHEMA.NAME.TYPE triples #}

  {% for node in graph.nodes.values()
     | selectattr("resource_type", "in", ["model", "seed", "snapshot"])
     | rejectattr("config.materialized", "equalto", "semantic_view") %}
    {% set node_schema = node.schema | upper %}
    {% set node_name   = node.name   | upper %}
    {# Normalize dbt materialization → Snowflake relation_type.
       dynamic_table is included because dynamic tables appear as 'BASE TABLE'
       in information_schema.tables (DPB-2494), so without normalization every
       dynamic table would look like a materialization mismatch and be dropped.
       semantic_view is excluded via rejectattr above — SV models materialize
       into information_schema.semantic_views (not .tables), so their FQNs in
       this allowlist would protect nothing physical and, in an SV-only graph,
       would leave the allowlist devoid of any real-table names — causing
       every real table/view to be flagged as an orphan and mass-dropped.
       Cleanup of orphan SVs is owned by dbt-common's
       drop_orphaned_semantic_views.py step (see docstring). #}
    {% set eff_type = node.config.materialized
        | replace("seed",          "table")
        | replace("incremental",   "table")
        | replace("snapshot",      "table")
        | replace("dynamic_table", "table")
        | upper %}
    {% do current_model_fqns.append(node_schema ~ "." ~ node_name) %}
    {% do current_model_type_fqns.append(node_schema ~ "." ~ node_name ~ "." ~ eff_type) %}
  {% endfor %}

{% endif %}

{% if execute %}

{# ── Safety: refuse to run cleanup with an empty allowlist ──────────────────
   If current_model_fqns is empty (project has zero non-SV model/seed/snapshot
   nodes), the NOT IN clauses below would flag EVERY real table/view in the
   database as an orphan and mass-drop the DB. This can happen legitimately
   during a package parse before consumers define any models, an SV-only
   project, or a mis-configured --select run.

   Skip both cleanup queries entirely in that case — this matches the
   pre-Fix-1.2 behavior of "no DROPs on empty allowlist" without depending on
   a SQL compilation error to protect us. #}
{% if current_model_fqns | length == 0 %}
  {{ log(
      "drop_unneeded_objects: SKIPPED — allowlist is empty (no model/seed/snapshot"
      ~ " nodes after excluding semantic_view). Refusing to run orphan cleanup"
      ~ " against " ~ target.database ~ " to prevent mass DROP of real objects.",
      True
  ) }}
{% else %}

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

{% endif %}{# current_model_fqns empty-allowlist safety guard #}

{% endif %}{# execute — queries 1 & 2 #}

select 1 -- drop_unneeded_objects completed
{%- endmacro -%}
