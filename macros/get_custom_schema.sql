{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none or custom_schema_name | trim == '' -%}

        {%- if node.package_name == 'dbt_project_evaluator' -%}
            {# Force dbt_project_evaluator models to UTIL_COMMON.
               The CI Python script injects +schema at build time, but this macro
               guards the compile step which runs before that injection. #}
            {{ 'UTIL_COMMON' }}

        {%- else -%}
            {# All other models — root project or other packages — must declare
               an explicit +schema in dbt_project.yml. Schemas are centrally
               provisioned via DPI; there is no valid default to fall back to. #}
            {{ exceptions.raise_compiler_error(
                "\n\n[Schema Enforcement] Model '" ~ node.name ~ "'"
                ~ " (package: " ~ node.package_name ~ ")"
                ~ " has no +schema configured.\n"
                ~ "  All models must map to an explicit schema declared in dbt_project.yml.\n"
                ~ "  Schemas are centrally provisioned — contact the DPI Data Platform team\n"
                ~ "  if a new schema is needed."
            ) }}
        {%- endif -%}

    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}