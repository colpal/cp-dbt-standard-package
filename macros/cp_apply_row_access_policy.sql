{% macro cp_apply_row_access_policy(table_name, policy_name, policy_columns) -%}
    {% set policy_col_list -%}
    ({{ '"' }}{{ policy_columns|join('", "') }}{{ '"' }})
    {% endset %}

    {% set query_policy_verification %}
        SELECT policy_db, policy_schema, policy_name
        FROM table(information_schema.policy_references(ref_entity_name => '{{ table_name }}', ref_entity_domain => 'table'))
        WHERE policy_status = 'ACTIVE' and policy_kind = 'ROW_ACCESS_POLICY'
    {% endset %}
    {% set policy_verification = run_query(query_policy_verification) %}

    {% if execute %}
        {% set results_db_list = policy_verification.columns[0].values() %}
        {% set results_schema_list = policy_verification.columns[1].values() %}
        {% set results_policy_list = policy_verification.columns[2].values() %}
    {% else %}
        {% set results_policy_list = [] %}
    {% endif %}

    {#- Use the shared cp_is_iceberg() helper (defined in iceberg_overrides.sql)
        so RAP application uses the exact same Iceberg detection rule as the
        materialization / tagging / contract-bypass paths. The prior local
        `catalog_name`-only check missed models flagged with
        `table_format='iceberg'` and could emit `ALTER TABLE` on an Iceberg
        relation (Snowflake requires `ALTER ICEBERG TABLE`). -#}
    {%- set is_iceberg = cp_dbt_standard_package.cp_is_iceberg() -%}
    {#- Both ALTER variants get IF EXISTS so the macro is idempotent when the
        RAP is applied on-run-end but the target relation has not yet been
        materialized (e.g. a first-time PR build where the RAP macro compiles
        before the referenced downstream table is created). -#}
    {%- set alter_cmd = 'ALTER ICEBERG TABLE IF EXISTS' if is_iceberg else 'ALTER TABLE IF EXISTS' -%}

    {% if not results_policy_list %}
        {{ alter_cmd }} {{ table_name }}
            ADD ROW ACCESS POLICY {{ policy_name }}
            ON {{ policy_col_list }};
    {% else %}
        {% set full_result_name = results_db_list[0] ~ '.' ~ results_schema_list[0] ~ '.' ~ results_policy_list[0] %}
        {% if not full_result_name == policy_name %}
            {{ alter_cmd }} {{ table_name }}
                DROP ROW ACCESS POLICY {{ full_result_name }};
            {{ alter_cmd }} {{ table_name }}
                ADD ROW ACCESS POLICY {{ policy_name }}
                ON {{ policy_col_list }};
        {% endif %}
    {% endif %}
{% endmacro %}
