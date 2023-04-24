{% macro set_query_tag() -%}
  {% set new_query_tag = model.name %}  

  {% if new_query_tag %}
    {% do run_query("alter session set query_tag = '{}'".format(model.name)) %}  
  {% endif %}

  {{ return(none)}}

{% endmacro %}
