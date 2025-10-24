{% macro set_query_tag(extra = {}) -%}
    
    {# Get warehouse recommendation from lookup table #}
    {% set relation = api.Relation.create(
        database='OPS_CUR',
        schema='WH_RECOMMENDATIONS',
        identifier='DIM_WAREHOUSE_RECOMMENDATION'
    ) %}
    
    {# Build query parameters #}
    {% set airflow_run = env_var('AIRFLOW_RUN', 'true') %}
    {% set where_statement = "source_uri = '" ~ model.name ~ "' and airflow = '" ~ airflow_run ~ "'" %}
    
    {# Get recommended warehouse name #}
    {% set warehouse = dbt_utils.get_column_values(
        relation,
        'RECOMMENDED_WAREHOUSE_NAME',
        default=['CP_DBT_LARGE_WH_V2'],
        where=where_statement
    ) %}
    {% set warehouse_name = warehouse[0] if warehouse else 'CP_DBT_LARGE_WH_V2' %}
    
    {# Prepare query tag with model metadata #}
    {% set merged_extra = extra.copy() %}
    {% do merged_extra.update({
        'invocation_id': invocation_id,
        'model': model.name,
        'is_airflow_run': airflow_run
    }) %}
    
    {# Set query tag using available method #}
    {% if adapter.check_macro_exists('dbt_snowflake_query_tags', 'unset_query_tag') %}
        {# Use dbt_snowflake_query_tags package if available #}
        {% set result = adapter.dispatch('set_query_tag', 'dbt_snowflake_query_tags')(extra=merged_extra) %}
    {% else %}
        {# Fallback to direct SQL command #}
        {% do run_query('ALTER SESSION SET query_tag = "{}"'.format(merged_extra)) %}
    {% endif %}
    
    {# Set warehouse for this session #}
    {% do run_query('USE WAREHOUSE "' ~ warehouse_name.upper() ~ '"') %}

{%- endmacro %}
