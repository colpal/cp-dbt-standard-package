{% macro unset_query_tag(original_query_tag) -%}

    {# Check if dbt_snowflake_query_tags is installed #}
    {% if dbt_snowflake_query_tags in context %}

        {% do return(dbt_snowflake_query_tags.unset_query_tag(original_query_tag)) %}

    {% else %}

        {# Fallback logic if package is not installed #}
        {% if original_query_tag %}
            {% do run_query("alter session set query_tag = '{}'".format(original_query_tag)) %}
        {% else %}
            {% do run_query("alter session unset query_tag") %}
        {% endif %}

    {% endif %}

    {% set warehouseName = env_var('DBT_SF_WAREHOUSE') if warehouse else 'CP_DBT_XSMALL_WH_V2' %}
    {% do run_query('USE WAREHOUSE "' ~ warehouseName.upper() ~ '"') %}

{% endmacro %}
