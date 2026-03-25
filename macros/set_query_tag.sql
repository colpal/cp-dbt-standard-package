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
      
      {# Temporarily scale down to XSMALL just for the lookup query to save costs #}
      {% do run_query('use warehouse CP_DBT_XSMALL_WH') %}

      {# Fetch SF_DATABASE and uppercase it for safe substring matching #}
      {% set sf_database = env_var('SF_DATABASE', '').upper() %}
      
      {# Safely determine the database using substring matching #}
      {% if 'DEV' in sf_database %}
          {% set db = 'DEV_SF_ANALYTICS_HUB' %}
      {% elif 'PROD' in sf_database %}
          {% set db = 'PROD_SF_ANALYTICS_HUB' %}
      {% else %}
          {# Fail fast if the environment prefix is unknown #}
          {% do exceptions.raise_compiler_error("Cannot determine environment from SF_DATABASE. Must contain 'DEV' or 'PROD'. Got database name: " ~ sf_database) %}
      {% endif %}
      
      {# Create the relation for the recommendation table #}
      {% set rec_table = api.Relation.create(
          database=db, 
          schema='WH_RECOMMENDATION_ANALYSIS', 
          identifier='WEEK_SOURCE_SIZING_RECOMMENDATIONS_TBL'
      ) %}

      {# Lookup the recommended warehouse #}
      {% set where_stmt = "source_uri = '" ~ model.name ~ "' and airflow = '" ~ airflow_run ~ "'" %}
      
      {# Note: We use dbt_utils to fetch the value #}
      {% set wh_list = dbt_utils.get_column_values(
          table=rec_table, 
          column='RECOMMENDED_WAREHOUSE_NAME', 
          default=['CP_DBT_LARGE_WH'], 
          where=where_stmt
      ) %}
      
      {# Route the model to the recommended warehouse #}
      {% set selected_wh = wh_list[0] if wh_list else 'CP_DBT_LARGE_WH' %}
      {% do run_query("USE WAREHOUSE " ~ selected_wh.upper()) %}
      
  {% endif %}

{%- endmacro %}
