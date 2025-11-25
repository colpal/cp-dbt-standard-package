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

-- set central tag schema
{# ============================================================
   Snowflake Tagging Package
   Updated to log Snowflake tags ONCE only
   ============================================================ #}

-- set central tag schema
{% macro get_tag_config() %}
    {% set config = {
        'tag_database': 'OPS_CUR',
        'tag_schema': 'TAGS'
    } %}
    {{ return(config) }}
{% endmacro %}

-- retrieve all available Snowflake tags from central schema
{% macro get_snowflake_tags() %}

    {% set config = cp_dbt_standard_package.get_tag_config() %}

    {% set sql %}
        SHOW TAGS IN SCHEMA {{ config.tag_database }}.{{ config.tag_schema }}
    {% endset %}

    {{ log("Retrieving available tags from: " ~ config.tag_database ~ "." ~ config.tag_schema, info=true) }}

    {% set rows = run_query(sql) %}
    {% set tag_list = [] %}

    {% if execute %}
        {% for row in rows %}
            {% set tag_name = row["name"] | string %}
            {% set allowed_vals_str = row["allowed_values"] | string if row["allowed_values"] is not none else "" %}

            {% set allowed_values = [] %}
            {% if allowed_vals_str.startswith("[") %}
                {% set cleaned = allowed_vals_str.strip("[]") %}
                {% for item in cleaned.split(",") %}
                    {% set clean = item | replace('"', '') | trim %}
                    {% if clean %}
                        {% do allowed_values.append(clean) %}
                    {% endif %}
                {% endfor %}
            {% endif %}

            {% do tag_list.append({
                'tag_name': tag_name,
                'allowed_values': allowed_values
            }) %}
        {% endfor %}
    {% endif %}

    {{ log("Available Snowflake Tags:", info=true) }}
    {% for tag in tag_list %}
        {{ log(" - " ~ tag.tag_name ~ " (allowed values: " ~ tag.allowed_values ~ ")", info=true) }}
    {% endfor %}

    {{ return(tag_list) }}

{% endmacro %}


{# ============================================================
   APPLY TAG TO MODEL
   ============================================================ #}
{% macro apply_tag(database_nm, schema, identifier, tag_name, tag_value, relation_type=none) %}

    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags() %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {# Does the tag exist? #}
    {% for tag in available_tags %}
        {% if tag.tag_name | upper == tag_name | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}

    {% if not ns.tag_exists %}
        {{ log("ERROR: Tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Skipping.", info=true) }}
        {{ return() }}
    {% endif %}

    {% set tag_name = ns.matching_tag %}

    {# Validate allowed values #}
    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}

        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value | upper == tag_value | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}

        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '" ~ tag_value ~ "' not allowed for tag '" ~ tag_name ~ "'.", info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}

        {% set tag_value = val_ns.matched_value %}
    {% endif %}

    {# Identify relation type #}
    {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
    {% set relation_type = relation.type | upper if relation else 'TABLE' %}

    {# Apply tag #}
    {% set sql %}
      ALTER {{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Applied tag '" ~ tag_name ~ "' to " ~ schema ~ "." ~ identifier, info=true) }}

{% endmacro %}


{# ============================================================
   APPLY COLUMN TAG
   ============================================================ #}
{% macro apply_column_tag(database_nm, schema, identifier, column_name, tag_name, tag_value, relation_type=none) %}

    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags() %}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {% for tag in available_tags %}
        {% if tag.tag_name | upper == tag_name | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}

    {% if not ns.tag_exists %}
        {{ log("ERROR: Column tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Skipping.", info=true) }}
        {{ return() }}
    {% endif %}

    {% set tag_name = ns.matching_tag %}

    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}

        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value | upper == tag_value | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}

        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '" ~ tag_value ~ "' not allowed for column tag '" ~ tag_name ~ "'.", info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
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
    {{ log("Applied column tag '" ~ tag_name ~ "' to " ~ column_name ~ " in " ~ schema ~ "." ~ identifier, info=true) }}

{% endmacro %}


{# ============================================================
   PROCESS TAGGING AT END OF RUN
   ============================================================ #}
{% macro tag_models_on_run_end(changed_models=None) %}
    {{ log("Starting tag application process", info=true) }}

    {% if changed_models is string %}
        {% set changed_models = fromjson(changed_models) %}
    {% endif %}

    {% if not changed_models or changed_models | length == 0 %}
        {{ log("No changed_models provided — skipping tagging.", info=true) }}
        {% set models_to_tag = [] %}
    {% else %}
        {{ log("Applying tags to deployed models: " ~ changed_models, info=true) }}
        {% set models_to_tag = changed_models %}
    {% endif %}

    {% for node_id in models_to_tag %}
        {% if node_id in graph.nodes %}
            {% set node = graph.nodes[node_id] %}

            {% if node.resource_type == 'model' %}
                {% set model_database = node.database %}
                {% set model_schema = node.schema %}
                {% set model_name = node.name %}

                {{ log("Processing model: " ~ model_database ~ "." ~ model_schema ~ "." ~ model_name, info=true) }}

                {# Table-level tags #}
                {% if node.config.snowflake_tags is defined %}
                    {% for tag_name, tag_value in node.config.snowflake_tags.items() %}
                        {{ cp_dbt_standard_package.apply_tag(model_database, model_schema, model_name, tag_name, tag_value) }}
                    {% endfor %}
                {% endif %}

                {# Column-level tags #}
                {% for col_name, col in node.columns.items() %}
                    {% if col.meta is defined and col.meta.snowflake_tags is defined %}
                        {% for tag_name, tag_value in col.meta.snowflake_tags.items() %}
                            {{ cp_dbt_standard_package.apply_column_tag(model_database, model_schema, model_name, col_name, tag_name, tag_value) }}
                        {% endfor %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {{ log("Tag application process completed.", info=true) }}
{% endmacro %}
