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
    {% set show_tags_query_output = run_query(sql) %}
    
    {% set tag_list = [] %}
    
    {% if execute %}
        {% for row in show_tags_query_output %}
            {% set tag_name = row["name"]|string %}
            {% set allowed_vals_str = row["allowed_values"]|string if row["allowed_values"] is not none else "" %}
            
            {# process allowed values #}
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

-- apply tag to a model with validation
{% macro apply_tag(database_nm, schema, identifier, tag_name, tag_value, relation_type=none) %}
    {# get available tags for validation #}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags() %}
    
    {# use namespace for variables that need to persist outside the loop #}
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {# check if tag exists #}
    {% for tag in available_tags %}
        {% if tag.tag_name.strip() | upper == tag_name.strip() | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}
    
    {# mismatch error #}
    {% if not ns.tag_exists %}
        {{ log("ERROR: Tag '" ~ tag_name ~ "' doesn't exist in Snowflake. Tag will NOT be applied.", info=true) }}
        {{ return() }}
    {% endif %}
    
    {# use the matched tag name for all further operations #}
    {% set tag_name = ns.matching_tag %}
    
    {# validate allowed values if specified #}
    {% if ns.allowed_values | length > 0 %}
        {% set val_ns = namespace(is_valid=false, matched_value="") %}
        
        {% for allowed_value in ns.allowed_values %}
            {% if allowed_value.strip() | upper == tag_value.strip() | upper %}
                {% set val_ns.is_valid = true %}
                {% set val_ns.matched_value = allowed_value %}
            {% endif %}
        {% endfor %}
        
        {% if not val_ns.is_valid %}
            {{ log("ERROR: Value '"
                ~ tag_value ~
                "' not in allowed values for tag '"
                ~ tag_name ~
                "'. Tag will NOT be applied.",
                info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}
        
        {# use the matched value #}
        {% set tag_value = val_ns.matched_value %}
    {% endif %}

    {% set relation = adapter.get_relation(database, schema, identifier) %}
    
    {% if relation %}
        {% set relation_type = relation.type | upper %}
    {% else %}
        {% set relation_type = 'TABLE' %}
    {% endif %}

    {# apply tag using fully qualified tag name #}
    {% set sql %}
      ALTER {{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }} 
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Applied tag '" ~ tag_name ~ "' to " ~ schema ~ "." ~ identifier, info=true) }}
{% endmacro %}

{% macro apply_column_tag(database_nm, schema, identifier, column_name, tag_name, tag_value, relation_type=none) %}
    {# get available tags for validation #}
    {% set config = cp_dbt_standard_package.get_tag_config() %}
    {% set available_tags = cp_dbt_standard_package.get_snowflake_tags() %}
    
    {# use namespace for variables that need to persist outside the loop #}
    {% set ns = namespace(tag_exists=false, matching_tag="", allowed_values=[]) %}
    
    {# check if tag exists #}
    {% for tag in available_tags %}
        {% if tag.tag_name.strip() | upper == tag_name.strip() | upper %}
            {% set ns.tag_exists = true %}
            {% set ns.matching_tag = tag.tag_name %}
            {% set ns.allowed_values = tag.allowed_values %}
        {% endif %}
    {% endfor %}
    
    {# mismatch error #}
    {% if not ns.tag_exists %}
        {{ log("ERROR: Tag '"
            ~ tag_name ~
            "' doesn't exist in Snowflake. Column tag will NOT be applied.",
            info=true) }}
        {{ return() }}
    {% endif %}
    
    {# use the matched tag name for all further operations #}
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
            {{ log("ERROR: Value '"
                ~ tag_value ~
                "' not in allowed values for tag '"
                ~ tag_name ~
                "'. Column tag will NOT be applied.",
                info=true) }}
            {{ log("Allowed values: " ~ ns.allowed_values | join(', '), info=true) }}
            {{ return() }}
        {% endif %}
        
        {# use the matched value #}
        {% set tag_value = val_ns.matched_value %}
    {% endif %}

    {% set relation = adapter.get_relation(database_nm, schema, identifier) %}
    {% if relation %}
        {% set relation_type = relation.type | upper %}
    {% else %}
        {% set relation_type = 'TABLE' %}
    {% endif %}

    {# apply tag using fully qualified tag name #}
    {% set sql %}
      ALTER {{ relation_type }} {{ database_nm }}.{{ schema }}.{{ identifier }} 
      MODIFY COLUMN {{ column_name }}
      SET TAG {{ config.tag_database }}.{{ config.tag_schema }}.{{ tag_name }} = '{{ tag_value }}'
    {% endset %}

    {% do run_query(sql) %}
    {{ log("Applied tag '"
        ~ tag_name ~
        "' to column "
        ~ column_name ~
        " in " ~ database_rm ~ "." ~ schema ~ "." ~ identifier,
        info=true) }}
{% endmacro %}

-- process models and apply tags after run
{% macro tag_models_on_run_end() %}
    {% if env_var('WORKFLOW_NAME', '') == 'Initialize DBT Artifact' %}
      {{ return() }}
    {% endif %}
  
    {{ log("Starting tag application process", info=true) }}
    
    {% for node_id in graph.nodes %}
        {% set node = graph.nodes[node_id] %}
        
        {% if node.resource_type == 'model' %}
            {% set model_database= node.database %}
            {% set model_schema = node.schema %}
            {% set model_name = node.name %}
            
            {% if node.config.snowflake_tags is defined %}
                {{ log("Processing table tags for "
                    ~ model_database ~
                    "." ~ model_schema ~ "." ~ model_name,
                    info=true) }}
                {% for tag_name, tag_value in node.config.snowflake_tags.items() %}
                    {{ cp_dbt_standard_package.apply_tag(model_database, model_schema, model_name, tag_name, tag_value, 'TABLE') }}
                {% endfor %}
            {% endif %}
            
            {% if node.columns is defined %}
                {{ log("Processing column tags for " ~ model_name, info=true) }}
                {% for column_name, column in node.columns.items() %}
                    {% if column.meta is defined and column.meta.snowflake_tags is defined %}
                        {{ log("Processing column: " ~ column_name, info=true) }}
                        {% for tag_name, tag_value in column.meta.snowflake_tags.items() %}
                            {{ cp_dbt_standard_package.apply_column_tag(model_database, model_schema, model_name, column_name, tag_name, tag_value, 'TABLE') }}
                        {% endfor %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endif %}
    {% endfor %}
{% endmacro %}
