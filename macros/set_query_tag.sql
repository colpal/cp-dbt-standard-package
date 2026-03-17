{% macro set_query_tag(extra = {}) -%}
    {% do run_query('use warehouse CP_DBT_XSMALL_WH_V2') %} # enabling recommendation query to run on xsmall warehouse 
    {% set relation = api.Relation.create(
        database='OPS_CUR', 
        schema='WH_RECOMMENDATIONS', 
        identifier='DIM_WAREHOUSE_RECOMMENDATION'
    ) %}
    
    {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}
    {% set where_statement = "source_uri = '" ~ model.name ~ "' and airflow = '" ~ airflow_run ~ "'" %}  

    {% set warehouse = dbt_utils.get_column_values(
        relation, 
        'RECOMMENDED_WAREHOUSE_NAME', 
        default=['CP_DBT_LARGE_WH_V2'], 
        where=where_statement
    ) %}
    {% set warehouseName = warehouse[0] if warehouse else 'CP_DBT_LARGE_WH_V2' %}
    
    {% set merged_extra = extra.copy() %}
    {% do merged_extra.update({
        'invocation_id': invocation_id, 
        'model': model.name, 
        'is_airflow_run': airflow_run
    }) %}
    
    {% set result = adapter.dispatch('set_query_tag', 'dbt_query_tags')(extra=merged_extra) %}
    {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}

{%- endmacro %}
