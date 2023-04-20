{% macro set_query_tag() -%}
    {% set new_query_tag = model.name %}
    {% do run_query("alter session set query_tag = {}".format(new_query_tag)) %}
{% endmacro %}
