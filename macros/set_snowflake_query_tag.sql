{%- macro set_snowflake_query_tag(tag = '') %}
    {% set new_tag = model.name %}
    {% do run_query("alter session set query_tag = '{}{}'".format(invocation_id, new_tag)) %}
{%- endmacro %}

