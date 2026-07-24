{% macro set_query_tag(extra = {}) -%}
    {% do run_query('use warehouse CP_DBT_XSMALL_WH_V2') %} 
    {% set relation = api.Relation.create(
        database='OPS_CUR', 
        schema='WH_RECOMMENDATIONS', 
        identifier='DIM_WAREHOUSE_RECOMMENDATION'
    ) %}
    
    {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}

    {% set active_db = model.database | string | upper %}
    {% set search_db = active_db[:-3] if active_db.endswith('_PD') else active_db %}
    
    {% set where_statement = "upper(source_uri) = upper('" ~ model.name ~ "') and upper(database_name) = '" ~ search_db ~ "' and lower(airflow) = lower('" ~ airflow_run ~ "')" %}

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
        'database': model.database,
        'is_airflow_run': airflow_run
    }) %}
    
    {% set result = adapter.dispatch('set_query_tag', 'dbt_query_tags')(extra=merged_extra) %}
    {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}

{%- endmacro %}
