{% macro apply_masking_policy(table_name, policy_name, column_name, policy_args) %}
    {% set policy_args_list %}
    ({{ '"' }}{{ policy_args|join('", "') }}{{ '"' }})
    {% endset %}
    
    {% set masked_column_args %}
    ("{{ column_name }}")
    {% endset %}

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
        {% set sql %}
        ALTER TABLE {{ table_name }}
        MODIFY COLUMN {{ column_name }}
        SET MASKING POLICY {{ policy_name }}
        USING {% if policy_args %} {{ policy_args_list }} {% else %} {{ masked_column_args }} {% endif %};
        {% endset %}
        {% do run_query(sql) %}
    {% else %}
        {% set existing_policy = results_db_list[0] ~ '.' ~ results_schema_list[0] ~ '.' ~ results_policy_list[0] %}
        {% if existing_policy != policy_name %}
             {% set unset_sql %}
            ALTER TABLE {{ table_name }}
            MODIFY COLUMN {{ column_name }}
            UNSET MASKING POLICY;
           {% endset %}
           {% do run_query(unset_sql) %}
          {% set set_sql %}
            ALTER TABLE {{ table_name }}
            MODIFY COLUMN {{ column_name }}
            SET MASKING POLICY {{ policy_name }}
            USING {% if policy_args %} {{ policy_args_list }} {% else %} {{ masked_column_args }} {% endif %};
            {% endset %}
           {% do run_query(set_sql) %}
        {% endif %}
    {% endif %}
{% endmacro %}
