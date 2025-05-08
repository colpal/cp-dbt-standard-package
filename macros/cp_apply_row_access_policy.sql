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

    {% if not results_policy_list %}
        ALTER TABLE IF EXISTS {{ table_name }} 
            ADD ROW ACCESS POLICY {{ policy_name }} 
            ON {{ policy_col_list }};
    {% else %}
        {% set full_result_name = results_db_list[0] ~ '.' ~ results_schema_list[0] ~ '.' ~ results_policy_list[0] %}
        {% if not full_result_name == policy_name %}
            ALTER TABLE IF EXISTS {{ table_name }}
                DROP ROW ACCESS POLICY {{ full_result_name }};
            ALTER TABLE IF EXISTS {{ table_name }} 
                ADD ROW ACCESS POLICY {{ policy_name }} 
                ON {{ policy_col_list }};
        {% endif %}
    {% endif %} 
{% endmacro %}