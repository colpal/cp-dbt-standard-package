{% macro set_query_tag(extra = {}) -%}
    {% set node = model if model is defined else none %}
    {% if node is none %}
        {% do return(None) %}
    {% endif %}
    {% set node_name = node.name %}
    {% set node_resource_type = node.resource_type %}
    {% set node_schema = node.schema if node.schema is not none else target.schema %}
    {% set node_database = node.database if node.database is not none else target.database %}
    {% if node_resource_type == "model" %}
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
    {% else %}
        {% set warehouse_name = None %}
        {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}
    {% endif %}
    
    {% set merged_extra = extra.copy() %}
    {% do merged_extra.update({
        'invocation_id': invocation_id, 
        'model': model.name, 
        'is_airflow_run': airflow_run
    }) %}
    
    {% set result = adapter.dispatch('set_query_tag', 'dbt_snowflake_query_tags')(extra=merged_extra) %}
    {% if node_resource_type == "model" and warehouse_name is not none %}
        {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}
    {% endif %}
    {{ return(result) }}

{%- endmacro %}
