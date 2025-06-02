{% macro data_type_mapping(data_type) %}
{{ log("DATA TYPE LENGTH = " ~ data_type, info=True) }}
    {% set mapped_data_type = data_type | lower %}
    {% if 'character varying' in mapped_data_type or 'varchar' in mapped_data_type %}
            VARCHAR
    {% else %}
        {{ data_type }}
    {% endif %}
{% endmacro %}