-- cp_materialization_semantic_view.sql
--
-- Colgate-Palmolive override of Snowflake-Labs/dbt_semantic_view's
-- `materialization_semantic_view_snowflake` macro.
--
-- WHY THIS EXISTS:
-- The dbt_semantic_view package runs CREATE OR REPLACE SEMANTIC VIEW under
-- whatever role is active at the start of the dbt invocation. In the CP
-- platform, dbt runs as the service account's default role (e.g. EX_DEPLOYMENT),
-- which lacks CREATE SEMANTIC VIEW on CUR-layer schemas. Only the
-- {DOMAIN}_DEPLOY_CUR role holds that privilege.
--
-- This override wraps the upstream DDL in a role switch, identical to the
-- pattern used in snowflake__create_schema. The role is restored after the
-- CREATE statement so subsequent dbt internals (relation cache, query tags)
-- run under the original session role.
--
-- CENTRALISATION:
-- Defined here in cp-dbt-standard-package so every domain using SVs gets
-- the role switch automatically — no dbt_project.yml pre-hook required.
--
-- COMPATIBILITY:
-- Tested against Snowflake-Labs/dbt_semantic_view 1.0.3. If the upstream
-- package's create.sql changes signature, re-validate this override.

{% materialization semantic_view, adapter='snowflake' -%}

  {# ── Role switch: use CUR deploy role if available ───────────────────── #}
  {% set cur_deploy_role = env_var('DBT_SF_CUR_DEPLOY_ROLE', '') %}
  {% set original_role = '' %}

  {% if cur_deploy_role %}
    {# Capture the current role so we can restore it after DDL #}
    {% call statement('get_current_role', fetch_result=true) %}
      SELECT CURRENT_ROLE()
    {% endcall %}
    {% set original_role = load_result('get_current_role')['data'][0][0] %}

    {% call statement('pre_sv_role_switch') %}
      USE ROLE {{ cur_deploy_role }}
    {% endcall %}

    {{ log("[cp_materialization_semantic_view] Switched to role: " ~ cur_deploy_role ~ " (was: " ~ original_role ~ ")", info=true) }}
  {% endif %}

  {# ── Delegate to upstream create logic ───────────────────────────────── #}
  {% set original_query_tag = set_query_tag() %}
  {% do dbt_semantic_view.snowflake__create_or_replace_semantic_view() %}

  {% set target_relation = this.incorporate(type='view') %}

  {% do unset_query_tag(original_query_tag) %}

  {# ── Restore original role ────────────────────────────────────────────── #}
  {% if cur_deploy_role and original_role and original_role != cur_deploy_role %}
    {% call statement('post_sv_role_restore') %}
      USE ROLE {{ original_role }}
    {% endcall %}
    {{ log("[cp_materialization_semantic_view] Restored role: " ~ original_role, info=true) }}
  {% endif %}

  {% do return({'relations': [target_relation]}) %}

{%- endmaterialization %}
