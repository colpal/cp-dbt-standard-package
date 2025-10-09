{% macro drop_unneeded_objects(dry_run='false') %}
{% if execute %}
  {% set current_models=['DBT_STATE'] %}
  {% set models_type=['DBT_STATE.TABLE'] %}  
  --Get the models that currently exist in dbt
  {% for node in graph.nodes.values()
     | selectattr("resource_type", "in", ["model", "seed", "snapshot"])%}
    {% do current_models.append(node.name) %} 
    {% do models_type.append(node.name ~ "." ~ node.config.materialized) %} 
  {% endfor %}
{% endif %}

{% set current_models_type=[] %}
{%- for model in models_type -%}
    {% do current_models_type.append(model | replace(".seed",".table") | replace(".incremental",".table") | replace(".snapshot",".table")) %} 
{%- endfor -%}

--Run a query to create the drop statements for all relations in snowflake that are NOT in the dbt project
{% set cleanup_query %}
      with models_to_drop as (
        select
          case 
            when table_type = 'BASE TABLE' then 'TABLE'
            when table_type = 'VIEW' then 'VIEW'
          end as relation_type,
          concat_ws('.', table_catalog, table_schema, table_name) as relation_name
        from 
          {{ target.database }}.information_schema.tables
        where table_schema not in ('UTIL_COMMON','UTIL_SECURITY','INFORMATION_SCHEMA')
          and table_name not in
            ({%- for model in current_models -%}
                '{{ model.upper() }}'
                {%- if not loop.last -%}
                    ,
                {% endif %}
            {%- endfor -%}))      
      select 
        'DROP ' || relation_type || ' IF EXISTS ' || relation_name || ';' as drop_commands
      from 
        models_to_drop
      
      -- intentionally exclude unhandled table_types, including 'external table`
      where drop_commands is not null
  {% endset %}

--Run a query to detect the materialization change and create the drop statements
{% set tab_vw_cleanup_query %}
      with tab_vw_to_drop as (
        select
        table_name,
          case 
            when table_type = 'BASE TABLE' then 'TABLE'
            when table_type = 'VIEW' then 'VIEW'
          end as relation_type, 
          concat_ws('.', table_catalog, table_schema, table_name) as relation_name
        from 
          {{ target.database }}.information_schema.tables
        where table_schema not in ('UTIL_COMMON','UTIL_SECURITY','INFORMATION_SCHEMA') ),


      tab_vw_to_drop_final as (
        select
          relation_type, 
          relation_name, 
          concat_ws('.', table_name, relation_type) as sf_tabnm_type
        from 
          tab_vw_to_drop
          where sf_tabnm_type not in 
            ({%- for model in current_models_type -%}
                '{{ model.upper() }}'
                {%- if not loop.last -%}
                    ,
                {% endif %}
            {%- endfor -%}) )

      select 
        'DROP ' || relation_type || ' IF EXISTS ' || relation_name || ';' as drop_tab_vw_command
      from 
        tab_vw_to_drop_final
      
      -- intentionally exclude unhandled table_types, including 'external table`
      where drop_tab_vw_command is not null
  {% endset %}

{% set drop_commands = run_query(cleanup_query).columns[0].values() %}
{% if drop_commands %}
{% do log("PRINTING CLEANUP_QUERY LOG", True) %}
  {% for drop_command in drop_commands %}
    {% do log(drop_command, True) %}
    {% if dry_run == 'false' %}
      {% do log('drop_command inside dry_run is false', True) %}
      {% do run_query(drop_command) %}
    {% endif %}
  {% endfor %}
{% else %}
  {% do log('No objects to clean.', True) %}
{% endif %}

{% set drop_tab_vw = run_query(tab_vw_cleanup_query).columns[0].values() %}
{% if drop_tab_vw %}
{% do log("PRINTING TAB_VW_CLEANUP_QUERY LOG", True) %}
  {% for drop_tabvw in drop_tab_vw %}
    {% do log(drop_tabvw, True) %}
    {% if dry_run == 'false' %}
      {% do log('drop tabvw inside dry_run is false', True) %}
      {% do run_query(drop_tabvw) %}
    {% endif %}
  {% endfor %}
{% else %}
  {% do log('No objects to clean.', True) %}
{% endif %}

{%- endmacro -%}
