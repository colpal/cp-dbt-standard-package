{%- macro unset_query_tag(original_query_tag) -%}
    {% if not model is defined %}
        {% do return(None) %}
    {% endif %}
    {% do return(cp_dbt_standard_package.unset_query_tag(original_query_tag)) %}
{%- endmacro -%}
