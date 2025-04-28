{% macro apply_masking_policy(table_name, policy_name, column_name, policy_args) -%}
    {% set policy_args_list -%}
    ({{ '"' }}{{ policy_args|join('", "') }}{{ '"' }})
    {% endset %}
    
    {% set query_column_existence %}
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = '{{ table_name.split(".")[0] }}'
          AND table_name = '{{ table_name.split(".")[1] }}'
          AND column_name = '{{ column_name }}'
    {% endset %}
    {% set column_existence_verification = run_query(query_column_existence) %}

    {% if execute %}
        {% set columns_list = column_existence_verification.columns[0].values() %}
    {% else %}
        {% set columns_list = [] %}
    {% endif %}

    {% if columns_list | length == 0 %}
        {% do raise("Column '{{ column_name }}' does not exist in table '{{ table_name }}'") %}
    {% endif %}

    {% set query_policy_verification %}
        SELECT policy_db, policy_schema, policy_name
        FROM table(information_schema.policy_references(ref_entity_name => '{{ table_name }}', ref_entity_domain => 'table'))
        WHERE policy_status = 'ACTIVE' and policy_kind = 'MASKING_POLICY' AND ref_column_name = '{{ column_name }}'
    {% endset %}
    {% set policy_verification = run_query(query_policy_verification) %}

    {% if execute %}
        {% set results_db_list = policy_verification.columns[0].values() %}
        {% set results_schema_list = policy_verification.columns[1].values() %}
        {% set results_policy_list = policy_verification.columns[2].values() %}
    {% else %}
        {% set results_policy_list = [] %}
    {% endif %}

    {% if results_policy_list | length == 0 %}
        ALTER TABLE IF EXISTS {{ table_name }}
            MODIFY COLUMN {{ column_name }}
            SET MASKING POLICY {{ policy_name }}
            USING {{ policy_args_list }};
    {% else %}
        {% set full_result_name = results_db_list[0] ~ '.' ~ results_schema_list[0] ~ '.' ~ results_policy_list[0] %}
        {% if full_result_name != policy_name %}
            ALTER TABLE IF EXISTS {{ table_name }}
                MODIFY COLUMN {{ column_name }}
                DROP MASKING POLICY {{ full_result_name }};
            ALTER TABLE IF EXISTS {{ table_name }}
                MODIFY COLUMN {{ column_name }}
                SET MASKING POLICY {{ policy_name }}
                USING {{ policy_args_list }};
        {% endif %}
    {% endif %}
{% endmacro %}