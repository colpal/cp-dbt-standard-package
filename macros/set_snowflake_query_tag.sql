{%- macro set_snowflake_query_tag(tag = '') %}
    {% set new_tag = model.name %}
    {% do run_query("alter session set query_tag = '{}'".format(dict(invocation_id = 'invocation_id', new_tag = new_tag))) %}
{%- endmacro %}

