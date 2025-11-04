{#
  Snowflake Tagging Package (`dbt_snowflake_tagging`)
  ----------------------------------------------------
    A set of macros to apply centrally created Snowflake tags to dbt models and columns
    based on configurations in schema YAML files.

  Version: 1.0.0

  ---------------- How to use ----------------

  1. Update packages.yml and enable post-run hook as outlined in readme.

  2. Usage - Define Tags on Models (in your model's `.yml` file):
     models:
       - name: my_model
         config:
           snowflake_tags:
             IS_CERTIFIED: 'TRUE'
         columns:
           - name: column_name
             meta:
               snowflake_tags:
                 TAG_NAME: 'tag_value_a'

  -----------------------------------------------
#}

/*
    Snowflake tagging macros
*/

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
            {% set tag_name = row["name"]|string %}
            {% set allowed_vals_str = row["allowed_values"]|string if row["allowed_values"] is not none else "" %}
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
        {{ log("ERROR: Tag '" ~ tag_name ~ "' not found in Snowflake. Skipping.", info=true) }}
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
            {{ log("ERROR: Invalid tag value '" ~ tag_value ~ "' for tag '" ~ tag_name ~ "'. Skipping.", info=true) }}
            {{ return() }}
        {% endif %}
        {% set tag_value = val_ns.matched_value %}
    {% endif %}
    {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
    {% set relation_type = relation.type | upper if relation else 'TABLE' %}
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
        {{ log("ERROR: Tag '" ~ tag_name ~ "' not found in Snowflake. Skipping column.", info=true) }}
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
            {{ log("Invalid value '" ~ tag_value ~ "' for tag '" ~ tag_name ~ "'. Skipping column.", info=true) }}
            {{ return() }}
        {% endif %}
        {% set tag_value = val_ns.matched_value %}
    {% endif %}
    {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
    {% set relation_type = relation.type | upper if relation else 'TABLE' %}
    {% set sql %}
      ALTER {{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }}
      MODIFY COLUMN {{ column_name }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}
    {% do run_query(sql) %}
    {{ log("Applied tag '" ~ tag_name ~ "' to column " ~ column_name ~ " in " ~ schema ~ "." ~ identifier, info=true) }}
{% endmacro %}

{# ------------------------------
    Helper macro for downstream lineage
------------------------------- #}
{% macro get_downstream_models(model_id, visited=[]) %}
    {% set children = graph.child_map.get(model_id, []) %}
    {% for child in children %}
        {% if child not in visited %}
            {% do visited.append(child) %}
            {% do visited.extend(cp_dbt_standard_package.get_downstream_models(child, visited)) %}
        {% endif %}
    {% endfor %}
    {{ return(visited) }}
{% endmacro %}

{# ------------------------------
    Main tagging macro
------------------------------- #}
{% macro tag_models_on_run_end(changed_models=none, propagate_downstream=true) %}
    {{ log("Starting tag application process", info=true) }}

    {% if changed_models is string %}
        {% set changed_models = fromjson(changed_models) %}
    {% endif %}

    {% set selective_tagging = changed_models is not none and changed_models | length > 0 %}
    {% if selective_tagging %}
        {{ log("Selective tagging enabled for changed models: " ~ changed_models, info=true) }}
    {% endif %}

    {% if propagate_downstream %}
        {{ log("Downstream propagation enabled", info=true) }}
    {% endif %}

    {% set models_to_tag = [] %}
    {% if selective_tagging %}
        {% do models_to_tag.extend(changed_models) %}
        {% if propagate_downstream %}
            {% for m in changed_models %}
                {% set downstream_nodes = cp_dbt_standard_package.get_downstream_models(m, []) %}
                {% for node in downstream_nodes %}
                    {% if node not in models_to_tag %}
                        {% do models_to_tag.append(node) %}
                    {% endif %}
                {% endfor %}
            {% endfor %}
        {% endif %}
    {% else %}
        {% set models_to_tag = graph.nodes.keys() %}
    {% endif %}

    {{ log("Final tagging list: " ~ models_to_tag, info=true) }}

    {% for node_id in models_to_tag %}
        {% set node = graph.nodes[node_id] %}
        {% if node.resource_type == 'model' %}
            {% set model_database = node.database %}
            {% set model_schema = node.schema %}
            {% set model_name = node.name %}

            {% if node.config.snowflake_tags is defined %}
                {% for tag_name, tag_value in node.config.snowflake_tags.items() %}
                    {{ cp_dbt_standard_package.apply_tag(model_database, model_schema, model_name, tag_name, tag_value, 'TABLE') }}
                {% endfor %}
            {% endif %}

            {% if node.columns is defined %}
                {% for column_name, column in node.columns.items() %}
                    {% if column.meta is defined and column.meta.snowflake_tags is defined %}
                        {% for tag_name, tag_value in column.meta.snowflake_tags.items() %}
                            {{ cp_dbt_standard_package.apply_column_tag(model_database, model_schema, model_name, column_name, tag_name, tag_value, 'TABLE') }}
                        {% endfor %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {{ log("Snowflake tagging process completed.", info=true) }}
{% endmacro %}
