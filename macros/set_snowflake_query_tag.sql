{%- macro set_snowflake_query_tag(tag = '') %}
    {% set new_tag = model.name %}
    {% do run_query(f"alter session set query_tag = {dict(invocation_id = invocation_id, new_tag = new_tag)}" %}
{%- endmacro %}

