{% macro set_query_tag() %}
    {% if execute and flags.WHICH in ('run', 'build') %}
    {% do run_query("alter session set query_tag = {}".format(model.name)) %}
    {% endif %}
{% endmacro %}
