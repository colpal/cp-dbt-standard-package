{% macro unset_query_tag(original_query_tag) -%}
    {% if not model is defined %}
        {% do return(None) %}
    {% endif %}
    {% set warehouseName = env_var('DBT_SF_WAREHOUSE') if warehouse else 'CP_DBT_XSMALL_WH' %}
    {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}
    {% do return(dbt_query_tags.unset_query_tag(original_query_tag)) %}

{% endmacro %}
