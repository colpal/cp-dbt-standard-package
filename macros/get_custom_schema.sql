{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if node.package_name == 'dbt_project_evaluator'
        and (custom_schema_name is none or custom_schema_name | trim == '') -%}
        {# Force dbt_project_evaluator nodes (models + seeds) to UTIL_COMMON when no
           schema is explicitly configured. The CI script injects +schema at build time,
           but this macro guards the compile step that runs before that injection. #}
        {{- 'UTIL_COMMON' -}}
    {%- else -%}
        {{- custom_schema_name | trim -}}
    {%- endif -%}

{%- endmacro %}