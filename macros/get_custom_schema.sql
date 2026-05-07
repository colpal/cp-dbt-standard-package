{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none or custom_schema_name | trim == '' -%}

        {%- if node.resource_type not in ('model', 'seed', 'snapshot') -%}
            {# Hooks, tests, analyses, and other non-deployable node types do not
               require an explicit schema — fall back to target.schema silently. #}
            {{ target.schema }}

        {%- elif node.package_name == 'dbt_project_evaluator' -%}
            {# Force dbt_project_evaluator models to UTIL_COMMON.
               The CI Python script injects +schema at build time, but this macro
               guards the compile step which runs before that injection. #}
            {{ 'UTIL_COMMON' }}

        {%- else -%}
            {# All models, seeds, and snapshots — root project or other packages —
               must declare an explicit +schema in dbt_project.yml. Schemas are
               centrally provisioned via DPI; there is no valid default to fall back to. #}
            {{ exceptions.raise_compiler_error(
                "\n\n[Schema Enforcement] Model '" ~ node.name ~ "'"
                ~ " (package: " ~ node.package_name ~ ", type: " ~ node.resource_type ~ ")"
                ~ " has no +schema configured.\n"
                ~ "  All models, seeds, and snapshots must map to an explicit schema\n"
                ~ "  declared in dbt_project.yml. Schemas are centrally provisioned —\n"
                ~ "  contact the DPI Data Platform team if a new schema is needed."
            ) }}
        {%- endif -%}

    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}