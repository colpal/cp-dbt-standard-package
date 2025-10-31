{#
    Snowflake Tagging Macros
    Centralized tagging utility for dbt projects

    Usage:
      - Defined inside cp-dbt-standard-package (shared macros repo)
      - Called externally as:  {{ cp_dbt_standard_package.tag_models_on_run_end() }}
#}

{% macro get_tag_config() %}
    {% set config = {
        'tag_database': 'OPS_CUR',
        'tag_schema': 'TAGS'
    } %}
    {{ return(config) }}
{% endmacro %}


{% macro get_snowflake_tags() %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    
    {% set sql %}
    SHOW TAGS IN SCHEMA {{ config.tag_database }}.{{ config.tag_schema }}
    {% endset %}
    
    {{ log("Retrieving available tags from: " ~ config.tag_database ~ "." ~ config.tag_schema, info=true) }}
    {% set show_tags_query_output = run_query(sql) %}
    {% set tag_list = [] %}
    
    {% if execute %}
        {% for row in show_tags_query_output %}
            {% set tag_name = row["name"] | string %}
            {% set allowed_vals_str = row["allowed_values"] | string if row["allowed_values"] is not none else "" %}
            {% set allowed_values = [] %}

            {% if allowed_vals_str and allowed_vals_str.startswith("[") and allowed_vals_str.endswith("]") %}
                {% set no_brackets = allowed_vals_str.strip("[]") %}
                {% set raw_items = no_brackets.split(",") %}
                {% for item in raw_items %}
                    {% set clean_item = item | replace('"', "") | trim %}
                    {% if clean_item != "" %}
                        {% do allowed_values.append(clean_item) %}
                    {% endif %}
                {% endfor %}
            {% endif %}

            {% do tag_list.append({'tag_name': tag_name, 'allowed_values': allowed_values}) %}
            {{ log("Found tag: " ~ tag_name ~ " with allowed values: " ~ allowed_values, info=true) }}
        {% endfor %}
    {% endif %}
    
    {{ return(tag_list) }}
{% endmacro %}


{% macro apply_tag(database_nm, schema, identifier, tag_name, tag_value, relation_type=none) %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags() %}
    
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {% for tag in available_tags %}
        {% if tag.tag_name.strip() | upper == tag_name.strip() | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}
    
    {% if not ns.tag_exists %}
        {{ log("ERROR: Tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Tag will NOT be applied.", info=true) }}
        {{ return() }}
    {% endif %}
    
    {% set tag_name = ns.matching_tag %}
    
    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}
        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value.strip() | upper == tag_value.strip() | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}
        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '" ~ tag_value ~ "' not in allowed values for tag '" ~ tag_name ~ "'. Tag will NOT be applied.", info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}
        {% set tag_value = val_ns.matched_value %}
    {% endif %}
    
    {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
    {% if relation %}
        {% set relation_type = relation.type | upper %}
    {% else %}
        {% set relation_type = 'TABLE' %}
    {% endif %}
    
    {% set sql %}
      ALTER {{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}
    
    {% do run_query(sql) %}
    {{ log("Applied tag '" ~ tag_name ~ "' to " ~ schema ~ "." ~ identifier, info=true) }}
{% endmacro %}


{% macro apply_column_tag(database_nm, schema, identifier, column_name, tag_name, tag_value, relation_type=none) %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags() %}
    
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {% for tag in available_tags %}
        {% if tag.tag_name.strip() | upper == tag_name.strip() | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}
    
    {% if not ns.tag_exists %}
        {{ log("ERROR: Tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Column tag will NOT be applied.", info=true) }}
        {{ return() }}
    {% endif %}
    
    {% set tag_name = ns.matching_tag %}
    
    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}
        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value.strip() | upper == tag_value.strip() | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}
        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '" ~ tag_value ~ "' not in allowed values for tag '" ~ tag_name ~ "'. Column tag will NOT be applied.", info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}
        {% set tag_value = val_ns.matched_value %}
    {% endif %}
    
    {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
    {% if relation %}
        {% set relation_type = relation.type | upper %}
    {% else %}
        {% set relation_type = 'TABLE' %}
    {% endif %}
    
    {% set sql %}
      ALTER {{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }}
      MODIFY COLUMN {{ column_name }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}
    
    {% do run_query(sql) %}
    {{ log("Applied tag '" ~ tag_name ~ "' to column " ~ column_name ~ " in " ~ schema ~ "." ~ identifier, info=true) }}
{% endmacro %}


{% macro tag_models_on_run_end() %}
    {{ log("Starting tag application process", info=true) }}

    {% for node_id in graph.nodes %}
        {% set node = graph.nodes[node_id] %}

        {% if node.resource_type == 'model' %}
            {% set model_database = node.database %}
            {% set model_schema = node.schema %}
            {% set model_name = node.name %}

            {% set config = node.get('config', {}) %}
            {% if config is mapping and config.get('snowflake_tags') is defined %}
                {{ log("Processing table tags for " ~ model_schema ~ "." ~ model_name, info=true) }}
                {% for tag_name, tag_value in config['snowflake_tags'].items() %}
                    {{ cp_dbt_standard_package.apply_tag(model_database, model_schema, model_name, tag_name, tag_value, 'TABLE') }}
                {% endfor %}
            {% endif %}

            {% if node.columns is defined and node.columns is mapping %}
                {% for column_name, column in node.columns.items() %}
                    {% set meta = column.get('meta', {}) %}
                    {% if meta is mapping and meta.get('snowflake_tags') is defined %}
                        {{ log("Processing column: " ~ column_name, info=true) }}
                        {% for tag_name, tag_value in meta['snowflake_tags'].items() %}
                            {{ cp_dbt_standard_package.apply_column_tag(model_database, model_schema, model_name, column_name, tag_name, tag_value, 'TABLE') }}
                        {% endfor %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endif %}
    {% endfor %}
{% endmacro %}

