-- {% macro set_query_tag() -%}
--   {% set new_query_tag = model.name %} 
--   {% if new_query_tag %}
--     {% set original_query_tag = get_current_query_tag() %}
--     {{ log("Setting query_tag to '" ~ new_query_tag ~ "'. Will reset to '" ~ original_query_tag ~ "' after materialization.") }}
--     {% do run_query("alter session set query_tag = '{}'".format()) %}
--     {{ return(original_query_tag)}}
--   {% endif %}
--   {{ return(none)}}
-- {%- endmacro %}
{%- macro set_snowflake_query_tag(tag = '') %}
    {% set new_query_tag = model.name %}
    {% do run_query("alter session set query_tag = '{}'".format({'model_name': new_query_tag, 'context_id': {{invocation_id}} })) %}
{%- endmacro %}