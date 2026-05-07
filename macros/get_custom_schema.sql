{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if custom_schema_name is none or custom_schema_name | trim == '' -%}

        {%- if node.resource_type not in ('model', 'seed', 'snapshot') -%}
            {# Hooks, tests, analyses, and other non-deployable node types do not
               require an explicit schema — fall back to target.schema silently. #}
            {{- target.schema -}}

        {%- elif node.config.materialized == 'ephemeral' -%}
            {# Ephemeral models are inlined at compile time and never written to the
               warehouse, so they have no schema requirement. Skip enforcement. #}
            {{- target.schema -}}

        {%- elif node.resource_type == 'seed' -%}
            {# Seeds fall back to target.schema silently when no schema is configured,
               preserving stable schema resolution across runs (no redeployment side-effects).
               Seeds can declare a schema via '+schema' in dbt_project.yml or via the
               'config: schema:' key in their YAML definition:
                 seeds:
                   - name: utm_parameters
                     config:
                       schema: seed_data
               When configured, custom_schema_name is already set and the outer else
               branch below returns it directly. #}
            {{- target.schema -}}

        {%- elif node.package_name == 'dbt_project_evaluator' -%}
            {# Force dbt_project_evaluator models to UTIL_COMMON.
               The CI Python script injects +schema at build time, but this macro
               guards the compile step which runs before that injection. #}
            {{- 'UTIL_COMMON' -}}

        {%- else -%}
            {# All models and snapshots should declare an explicit +schema in dbt_project.yml.
               Schemas are centrally provisioned via DPI. Falling back to target.schema and
               emitting a warning so teams can remediate without being blocked. #}
            {%- set _ = log(
                "\n[Schema Warning] Node '" ~ node.name ~ "'"
                ~ " (package: " ~ node.package_name ~ ", type: " ~ node.resource_type ~ ")"
                ~ " has no +schema configured — falling back to '" ~ target.schema ~ "'.\n"
                ~ "  All models and snapshots should map to an explicit schema\n"
                ~ "  declared in dbt_project.yml. Schemas are centrally provisioned —\n"
                ~ "  contact the DPI Data Platform team if a new schema is needed.",
                info=true
            ) -%}
            {{- target.schema -}}
        {%- endif -%}

    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}