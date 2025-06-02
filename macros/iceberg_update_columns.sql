{% macro iceberg_update_columns(source, target, temp_view_name) %}
{#{ log("SOURCE SQL = " ~ source, info=True)}#}
{% set model_columns = [] %}
{#  set model_columns = adapter.get_columns_in_relation(this)  #}
    {% set desc_temp_view_sql %}
        DESCRIBE VIEW {{ this.database}}.{{ this.schema }}.{{ temp_view_name }} 
    {% endset %} 
    {% set model_columns = run_query(desc_temp_view_sql) %}
{% set comma = joiner(", ") %}
{% for column in model_columns %}
    {{ comma() }}{{ target }}.{{ column.name }} = {{ source }}.{{ column.name }}
{% endfor %}
{% endmacro %}