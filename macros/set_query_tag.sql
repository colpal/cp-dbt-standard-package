{% macro set_query_tag() %}
  {% do run_query("alter session set query_tag = '{}'".format(model.name)) %}
{% endmacro %}
