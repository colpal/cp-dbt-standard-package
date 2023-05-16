{%- macro set_snowflake_query_tag(tag = '') %}
    {% set model = model.name %}
    {% do run_query('alter session set query_tag = "{}"'.format(dict(invocation_id = invocation_id, model_name = model))) %}
{%- endmacro %}

