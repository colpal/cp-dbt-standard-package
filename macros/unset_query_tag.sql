{% macro unset_query_tag(original_query_tag) -%}

    {% set warehouseName = env_var('DBT_SF_WAREHOUSE') if warehouse else 'CP_DBT_XSMALL_WH_V2' %}
    {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}
    {% do return(dbt_snowflake_query_tags.unset_query_tag(original_query_tag)) %}

{% endmacro %}
