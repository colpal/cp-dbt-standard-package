{% macro set_query_tag(extra = {}) -%}

  {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}

  {# 1. Global Tagging (Executes for Everyone) #}
  {% set merged_extra = extra.copy() %}
  {% do merged_extra.update({
      'invocation_id': invocation_id,
      'model': model.name,
      'is_airflow_run': airflow_run
  }) %}
  {% set result = adapter.dispatch('set_query_tag', 'dbt_query_tags')(extra=merged_extra) %}


  {# 2. Dynamic Warehouse Logic (Conditional Feature Toggle) #}
  {% if var('enable_dynamic_warehouse', false) %}

      {% set default_warehouse = var('warehouse_recommendation_default', 'CP_DBT_LARGE_WH') %}
      {% set lookup_warehouse = var('warehouse_recommendation_lookup', 'CP_DBT_XSMALL_WH') %}

      {# Scale down to lookup warehouse for the dim read #}
      {% do run_query('use warehouse ' ~ lookup_warehouse) %}

      {% set relation = api.Relation.create(
          database='OPS_CUR',
          schema='WH_RECOMMENDATIONS',
          identifier='DIM_WAREHOUSE_RECOMMENDATION'
      ) %}

      {% set rec_query %}
          select
              override_warehouse_name,
              recommended_warehouse_size
          from {{ relation }}
          where source_uri = '{{ model.name }}'
              and airflow = '{{ airflow_run }}'
          limit 1
      {% endset %}

      {% set selected_wh = default_warehouse %}
      {% if execute %}
          {% set results = run_query(rec_query) %}
          {% if results and results.rows | length > 0 %}
              {% set row = results.rows[0] %}
              {% if row[0] %}
                  {% set selected_wh = row[0] %}
              {% elif row[1] %}
                  {% set selected_wh = 'CP_DBT_' ~ v1_size_to_name(row[1]) ~ '_WH' %}
              {% endif %}
          {% endif %}
      {% endif %}

      {% do run_query("USE WAREHOUSE " ~ selected_wh.upper()) %}

  {% endif %}

{%- endmacro %}


{#
  Translate a generation-agnostic size token from
  OPS_CUR.WH_RECOMMENDATIONS.DIM_WAREHOUSE_RECOMMENDATION into the V1 named-pool
  size segment. Caps anything above LARGE at LARGE because V1 deploy roles do
  not have USAGE on CP_DBT_{X,2X,...}LARGE_WH. Strips hyphens so '2x-large'
  becomes '2XLARGE' (used only when the cap is relaxed; today the cap holds).
#}
{% macro v1_size_to_name(size_token) -%}
    {%- set cap_above_large = ['x-large', '2x-large', '3x-large', '4x-large', '5x-large', '6x-large'] -%}
    {%- set effective = 'large' if size_token in cap_above_large else size_token -%}
    {{- effective.replace('-', '') -}}
{%- endmacro %}
