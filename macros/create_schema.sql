{#
  Override of the default snowflake__create_schema macro to ensure schemas
  are created with the correct layer-scoped deploy role.

  Root cause being fixed:
    The dbt session role (set in profiles.yml) is always DBT_SF_CUR_DEPLOY_ROLE.
    When dbt needs to create a schema in a CON PD database (e.g. MD_CON_PD),
    it runs CREATE SCHEMA using the session role — which lacks privileges on
    CON databases — causing error 003001: Insufficient privileges.

    This occurs specifically when `clean_up_pd_db` (called after a prior PR merge)
    has dropped all schemas from the CON PD database before a concurrent PR's
    push build fires. dbt's schema creation runs before any model pre-hooks, so
    the per-model `USE ROLE` pre-hooks never get a chance to switch the role.

  Fix:
    Before creating any schema, switch to the role that owns the target database
    layer (CON role for CON databases, CUR role for all others), then restore
    the session role immediately after.

  Note:
    Each dbt thread has its own Snowflake connection/session, so USE ROLE changes
    are fully isolated between concurrent threads.
#}
{% macro snowflake__create_schema(relation) -%}
  {%- set cur_role = env_var('DBT_SF_CUR_DEPLOY_ROLE') -%}
  {%- set con_role = env_var('DBT_SF_CON_DEPLOY_ROLE', cur_role) -%}
  {%- set target_role = con_role if '_CON' in (relation.database | upper) else cur_role -%}
  {%- set schema_fqn = relation.without_identifier() -%}

  {{ log("[create_schema] Switching to role " ~ target_role ~ " to create schema " ~ schema_fqn, info=true) }}
  {% call statement('use_role_for_schema') %}
    USE ROLE {{ target_role }}
  {% endcall %}

  {{ log("[create_schema] Creating schema " ~ schema_fqn, info=true) }}
  {% call statement('create_schema') %}
    CREATE SCHEMA IF NOT EXISTS {{ schema_fqn }}
  {% endcall %}

  {{ log("[create_schema] Restoring session role " ~ cur_role, info=true) }}
  {% call statement('restore_session_role') %}
    USE ROLE {{ cur_role }}
  {% endcall %}
{%- endmacro %}
